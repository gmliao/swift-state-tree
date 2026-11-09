import Foundation
import SwiftStateTree

public final class ReevaluationRunnerService: @unchecked Sendable {
    private var runner: (any ReevaluationRunnerProtocol)?
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

    public init(
        factory: any ReevaluationTargetFactory,
        projectorResolver: @escaping ReevaluationReplayProjectorResolver = ReevaluationReplayProjectorRegistry.defaultResolver
    ) {
        self.factory = factory
        self.projectorResolver = projectorResolver
        (requests, requestContinuation) = AsyncStream.makeStream()
    }

    deinit {
        requestContinuation.finish()
        driverTask?.cancel()
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
        runner = nil
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
        lock.lock()
        defer { lock.unlock() }
        guard !resultsQueue.isEmpty else {
            return nil
        }
        return resultsQueue.removeFirst()
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

    private func setRunnerInstance(_ runner: any ReevaluationRunnerProtocol, ticket: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(ticket) else { return false }
        self.runner = runner
        _status.phase = .verifying
        _status.totalTicks = runner.maxTickId + 1
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

        var queuedResult = result
        if let replayProjector {
            do {
                let projectedFrame = try replayProjector.project(result)
                queuedResult = ReevaluationStepResult(
                    tickId: result.tickId,
                    stateHash: result.stateHash,
                    recordedHash: result.recordedHash,
                    isMatch: result.isMatch,
                    actualState: result.actualState,
                    emittedServerEvents: result.emittedServerEvents,
                    recordedServerEvents: result.recordedServerEvents,
                    projectedFrame: projectedFrame
                )
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
        runner = nil
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
