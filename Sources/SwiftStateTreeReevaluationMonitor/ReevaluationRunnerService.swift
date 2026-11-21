import Foundation
import SwiftStateTree

public final class ReevaluationRunnerService: @unchecked Sendable {
    private var replayProjector: (any ReevaluationReplayProjecting)?
    private var verificationTask: Task<Void, Never>?
    private var _status: ReevaluationStatus = .init()
    private var resultsQueue: [ReevaluationStepResult] = []
    private let lock = NSLock()
    /// The current run's ticket: each start takes a new one, and a run writes its status and
    /// results only while its ticket is current, so a replaced run can't write.
    private var generation: UInt64 = 0
    /// Run requests from land turns (`requestVerification`), started by the driver outside them.
    private let requests: AsyncStream<(generation: UInt64, landType: String, recordFilePath: String)>
    private let requestContinuation: AsyncStream<(generation: UInt64, landType: String, recordFilePath: String)>.Continuation
    private var driverTask: Task<Void, Never>?
    private var runsStarted = 0
    private var runsStartedWaiters: [(id: UUID, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private let factory: any ReevaluationTargetFactory
    private let projectorResolver: ReevaluationReplayProjectorResolver
    /// The state type of the replay land this service feeds, when it feeds one
    /// (`expectReplayLandState`): a result is queued only with a resolved frame of that type, so
    /// the land's tick can't meet a frame it can't show (#521 PR 1b, S1).
    private var replayLandState: (id: ObjectIdentifier, name: String)?

    /// The most steps a run may take: its runner's last tick + 1 (#728).
    private let maxReplayTicks: Int64

    /// - Parameter maxReplayTicks: a run whose runner's last tick + 1 is past this fails before its
    ///   first step, whatever runner the factory made. A runner that opens a record file bounds
    ///   it too, at its own `maxReplayTicks`: raise both to allow longer records.
    public init(
        factory: any ReevaluationTargetFactory,
        projectorResolver: @escaping ReevaluationReplayProjectorResolver = ReevaluationReplayProjectorRegistry.defaultResolver,
        maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks
    ) {
        self.maxReplayTicks = maxReplayTicks
        self.factory = factory
        self.projectorResolver = projectorResolver
        (requests, requestContinuation) = AsyncStream.makeStream()
    }

    deinit {
        requestContinuation.finish()
        driverTask?.cancel()
    }

    /// Makes this service feed a replay land of state `State`: each result must carry a
    /// `ReevaluationReplayFrame` of that state type, or the run fails before it is queued.
    package func expectReplayLandState(_ state: any StateNodeProtocol.Type) {
        lock.lock()
        defer { lock.unlock() }
        replayLandState = (ObjectIdentifier(state), String(reflecting: state))
    }

    // MARK: Requests from land turns

    /// Starts the driver that runs requested verifications, once. Call it outside a land turn
    /// (the monitor's services factory does, when the land is created): the driver is the
    /// task that does the work a turn only requests.
    package func startDriver() {
        lock.lock()
        defer { lock.unlock() }
        guard driverTask == nil else { return }
        let requests = self.requests
        driverTask = Task { [weak self] in
            for await request in requests {
                guard let self else { return }
                self.startRun(generation: request.generation, landType: request.landType, recordFilePath: request.recordFilePath)
            }
        }
    }

    /// Requests a verification run, from a land turn: synchronous and non-blocking, it starts no
    /// task. It takes the run's ticket and sets the status to `.loading` (so a second request in
    /// a later turn sees the run under way), then hands the run to the driver.
    package func requestVerification(landType: String, recordFilePath: String) {
        let ticket = beginRun(recordFilePath: recordFilePath)
        requestContinuation.yield((ticket, landType, recordFilePath))
    }

    /// Takes a new run ticket, cancels the current run, resets the status to `.loading` and
    /// clears the results, under one lock: no reader sees a new ticket with the old run's
    /// status or results.
    private func beginRun(recordFilePath: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        verificationTask?.cancel()
        generation &+= 1
        _status = ReevaluationStatus()
        _status.phase = .loading
        _status.recordFilePath = recordFilePath
        resultsQueue.removeAll()
        return generation
    }

    public func getStatus() -> ReevaluationStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public func consumeResults() -> [ReevaluationStepResult] {
        lock.lock()
        defer { lock.unlock() }
        let results = resultsQueue
        resultsQueue.removeAll()
        return results
    }

    public func consumeNextResult() -> ReevaluationStepResult? {
        consumeNextResultWithTicket()?.result
    }

    /// The next result and the ticket of the run that queued it, read under one lock: a start
    /// clears the queue when it takes a new ticket, so the result is that run's.
    package func consumeNextResultWithTicket() -> (result: ReevaluationStepResult, ticket: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard !resultsQueue.isEmpty else {
            return nil
        }
        return (resultsQueue.removeFirst(), generation)
    }

    /// Fails the run `ticket` names, from the replay land that read one of its results and can't
    /// show it (#521 PR 1b): the status becomes `.failed` with `error`, the queue is cleared and
    /// the run stops. A later run (a newer ticket) is left alone.
    /// Returns whether the ticket was current. A stale ticket (a newer run began, or this one
    /// was already failed through it) changes nothing. A run that already failed keeps its first
    /// error.
    @discardableResult
    package func failRun(ticket: UInt64, error: ReevaluationReplayResolutionError) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(ticket) else { return false }
        // A new ticket, so the failed run can neither queue nor overwrite the status.
        generation &+= 1
        verificationTask?.cancel()
        resultsQueue.removeAll()
        if _status.phase != .failed {
            _status.phase = .failed
            _status.errorMessage = error.description
        }
        return true
    }

    private func updateStatus(_ block: (inout ReevaluationStatus) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        block(&_status)
    }


    /// Starts a verification run now, from outside a land turn (tests, tools). A land turn uses
    /// `requestVerification` instead.
    public func startVerification(landType: String, recordFilePath: String) {
        let ticket = beginRun(recordFilePath: recordFilePath)
        startRun(generation: ticket, landType: landType, recordFilePath: recordFilePath)
    }

    private func startRun(generation ticket: UInt64, landType: String, recordFilePath: String) {
        lock.lock()
        guard generation == ticket else {
            // A later request replaced this one before the driver reached it.
            lock.unlock()
            return
        }
        verificationTask?.cancel()
        replayProjector = projectorResolver(landType)
        lock.unlock()

        let task = Task { [weak self] in
            guard let self = self else { return }

            do {
                let newRunner = try await factory.createRunner(landType: landType, recordFilePath: recordFilePath)

                guard self.setRunnerInstance(newRunner, ticket: ticket) else { return }

                try await newRunner.prepare()

                while !Task.isCancelled {
                    if self.isPaused() {
                        try? await safeTaskSleep(for: .milliseconds(100))
                        continue
                    }

                    // This run steps only its own runner, and only while its ticket is current:
                    // a replaced run never steps the current run's runner.
                    guard self.isCurrent(ticket) else { break }

                    if let result = try await newRunner.step() {
                        let shouldContinue = self.processResult(result, ticket: ticket)
                        if !shouldContinue {
                            break
                        }
                    } else {
                        // Finished
                        self.updateStatus(ticket: ticket) { s in
                            if s.phase != .failed {
                                s.phase = .completed
                            }
                        }
                        break
                    }

                    // Yield or small delay to allow UI to breathe
                    await Task.yield()
                    // try? await Task.sleep(nanoseconds: 1_000_000)
                }
            } catch {
                if error is CancellationError {
                    return
                }
                self.updateStatus(ticket: ticket) { s in
                    s.phase = .failed
                    s.errorMessage = error.localizedDescription
                }
            }
        }

        lock.lock()
        if generation == ticket {
            verificationTask = task
        } else {
            task.cancel()
        }
        runsStarted += 1
        let ready = runsStartedWaiters.filter { $0.count <= runsStarted }
        runsStartedWaiters.removeAll { $0.count <= runsStarted }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }

    /// Whether `ticket` is still the current run's (under the lock).
    private func isCurrentLocked(_ ticket: UInt64) -> Bool { generation == ticket }

    /// False when the run is no longer current, or when its runner's tick count is refused: the
    /// status is then `.failed`, and the run ends before its first step.
    private func setRunnerInstance(_ runner: any ReevaluationRunnerProtocol, ticket: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(ticket) else { return false }
        // `ReevaluationRunnerProtocol` is public, so a runner can report any last tick: a count
        // that doesn't fit fails the run instead of trapping the process (#640).
        let (totalTicks, overflow) = runner.maxTickId.addingReportingOverflow(1)
        guard !overflow else {
            _status.phase = .failed
            _status.errorMessage = "the runner's last tick is \(runner.maxTickId), so its tick count doesn't fit in Int64"
            return false
        }
        guard totalTicks <= maxReplayTicks else {
            _status.phase = .failed
            _status.errorMessage = ReevaluationRecordContentError.replayTooLong(
                lastTick: runner.maxTickId, limit: maxReplayTicks
            ).description
            return false
        }
        _status.phase = .verifying
        _status.totalTicks = totalTicks
        return true
    }

    private func updateStatus(ticket: UInt64, _ block: (inout ReevaluationStatus) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(ticket) else { return }
        block(&_status)
    }

    private func isCurrent(_ ticket: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentLocked(ticket)
    }

    private func isPaused() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _status.phase == .paused
    }

    @discardableResult
    private func processResult(_ result: ReevaluationStepResult, ticket: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A replaced run's result is dropped, and the replaced run stops.
        guard isCurrentLocked(ticket) else { return false }

        // A replay land reads only a resolved frame of its own state type, with a state to show
        // (#521 PR 1b, S1). A run that feeds no replay land queues a stateless tick: it is
        // unverifiable, never a match (#180).
        if let expected = replayLandState {
            if let refusal = ReevaluationReplayFrame.refusal(of: result, forStateType: expected.id, named: expected.name) {
                _status.phase = .failed
                _status.errorMessage = refusal.description
                return false
            }
        }

        var queuedResult = result
        if let replayProjector {
            do {
                // A copy that keeps every other field (#521 M2): the pass mismatch and the frame.
                queuedResult = result.with(projectedFrame: try replayProjector.project(result))
            } catch {
                _status.phase = .failed
                _status.errorMessage = error.localizedDescription
                return false
            }
        }

        _status.currentTick = queuedResult.tickId
        _status.currentActualHash = queuedResult.stateHash
        _status.currentExpectedHash = queuedResult.recordedHash ?? "?"
        _status.currentIsMatch = queuedResult.isMatch

        if queuedResult.isMatch {
            _status.correctTicks += 1
        } else {
            _status.mismatchedTicks += 1
        }

        resultsQueue.append(queuedResult)
        return true
    }

    public func pause() {
        updateStatus { s in
            if s.phase == .verifying {
                s.phase = .paused
            }
        }
    }

    public func resume() {
        updateStatus { s in
            if s.phase == .paused {
                s.phase = .verifying
            }
        }
    }

    public func stop() {
        lock.lock()
        // A new ticket, so the stopped run can't write after this.
        generation &+= 1
        verificationTask?.cancel()
        _status.phase = .idle
        resultsQueue.removeAll()
        lock.unlock()
    }

    /// The latest verification run's task, if one was started (tests only): awaiting its value
    /// waits until the run has set its terminal status, so a test needn't poll for it.
    func verificationTaskForTesting() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return verificationTask
    }

    /// The current run's ticket (tests only): a request or start takes a new one.
    func generationForTesting() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Waits until the driver (or `startVerification`) has started `count` runs in all (tests
    /// only), so a test can await a run a land turn requested.
    /// Returns once `count` runs have started, or when the waiting task is cancelled (a test's
    /// time limit cancels it), so a wrong wait fails its test instead of hanging the run.
    func waitForRunsStartedForTesting(_ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if runsStarted >= count || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                runsStartedWaiters.append((id, count, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = runsStartedWaiters.first { $0.id == id }
            runsStartedWaiters.removeAll { $0.id == id }
            lock.unlock()
            waiter?.continuation.resume()
        }
    }
}
