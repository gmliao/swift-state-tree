import Foundation
import SwiftStateTree

public final class ReevaluationRunnerService: @unchecked Sendable {
    private var runner: (any ReevaluationRunnerProtocol)?
    private var replayProjector: (any ReevaluationReplayProjecting)?
    private var verificationTask: Task<Void, Never>?
    private var _status: ReevaluationStatus = .init()
    private var resultsQueue: [ReevaluationStepResult] = []
    private let lock = NSLock()

    private let factory: any ReevaluationTargetFactory
    private let projectorResolver: ReevaluationReplayProjectorResolver

    public init(
        factory: any ReevaluationTargetFactory,
        projectorResolver: @escaping ReevaluationReplayProjectorResolver = ReevaluationReplayProjectorRegistry.defaultResolver
    ) {
        self.factory = factory
        self.projectorResolver = projectorResolver
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

    private func resetStatus(recordFilePath: String) {
        lock.lock()
        defer { lock.unlock() }
        _status = ReevaluationStatus()
        _status.phase = .loading
        _status.recordFilePath = recordFilePath
        resultsQueue.removeAll()
    }

    public func startVerification(landType: String, recordFilePath: String) {
        lock.lock()
        verificationTask?.cancel()
        replayProjector = projectorResolver(landType)
        lock.unlock()

        resetStatus(recordFilePath: recordFilePath)

        // Start new task
        let task = Task { [weak self] in
            guard let self = self else { return }

            do {
                let newRunner = try await factory.createRunner(landType: landType, recordFilePath: recordFilePath)

                self.setRunnerInstance(newRunner)

                try await newRunner.prepare()

                while !Task.isCancelled {
                    if self.isPaused() {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        continue
                    }

                    guard let activeRunner = self.getRunnerInstance() else { break }

                    if let result = try await activeRunner.step() {
                        let shouldContinue = self.processResult(result)
                        if !shouldContinue {
                            break
                        }
                    } else {
                        // Finished
                        self.updateStatus { s in
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
                self.updateStatus { s in
                    s.phase = .failed
                    s.errorMessage = error.localizedDescription
                }
            }
        }

        lock.lock()
        verificationTask = task
        lock.unlock()
    }

    private func setRunnerInstance(_ runner: any ReevaluationRunnerProtocol) {
        lock.lock()
        defer { lock.unlock() }
        self.runner = runner
        _status.phase = .verifying
        _status.totalTicks = runner.maxTickId + 1
    }

    private func getRunnerInstance() -> (any ReevaluationRunnerProtocol)? {
        lock.lock()
        defer { lock.unlock() }
        return runner
    }

    private func isPaused() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _status.phase == .paused
    }

    @discardableResult
    private func processResult(_ result: ReevaluationStepResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }

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
        verificationTask?.cancel()
        _status.phase = .idle
        runner = nil
        resultsQueue.removeAll()
        lock.unlock()
    }
}
