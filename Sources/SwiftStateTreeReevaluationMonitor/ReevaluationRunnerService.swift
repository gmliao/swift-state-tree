import Foundation
import SwiftStateTree

public final class ReevaluationRunnerService: @unchecked Sendable {
    private var runner: (any ReevaluationRunnerProtocol)?
    private var verificationTask: Task<Void, Never>?
    private var _status: ReevaluationStatus = .init()
    private let lock = NSLock()

    private let factory: any ReevaluationTargetFactory

    public init(factory: any ReevaluationTargetFactory) {
        self.factory = factory
    }

    public func getStatus() -> ReevaluationStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
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
    }

    private func setVerificationTask(_ task: Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        verificationTask = task
    }

    private func getVerificationTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return verificationTask
    }

    private func setRunnerInstance(_ runner: any ReevaluationRunnerProtocol) {
        lock.lock()
        defer { lock.unlock() }
        self.runner = runner
        _status.phase = .verifying
        _status.totalTicks = runner.maxTickId
    }

    private func getRunnerInstance() -> (any ReevaluationRunnerProtocol)? {
        lock.lock()
        defer { lock.unlock() }
        return runner
    }

    private func checkPause() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _status.phase == .paused
    }

    public func startVerification(landType: String, recordFilePath: String) {
        // Cancel existing task logic
        getVerificationTask()?.cancel()

        resetStatus(recordFilePath: recordFilePath)

        // Start new task
        // Capture factory and method args
        let factory = self.factory

        let task = Task {
            do {
                let newRunner = try await factory.createRunner(landType: landType, recordFilePath: recordFilePath)

                self.setRunnerInstance(newRunner)

                try await newRunner.prepare()

                while !Task.isCancelled {
                    if self.checkPause() {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        continue
                    }

                    guard let activeRunner = self.getRunnerInstance() else { break }

                    if let result = try await activeRunner.step() {
                        self.updateStatus { s in
                            s.currentTick = result.tickId
                            s.currentActualHash = result.stateHash
                            s.currentExpectedHash = result.recordedHash ?? "?"
                            s.currentIsMatch = result.isMatch

                            if result.isMatch {
                                s.correctTicks += 1
                            } else {
                                s.mismatchedTicks += 1
                            }
                        }
                    } else {
                        // Finished
                        self.updateStatus { s in s.phase = .completed }
                        break
                    }

                    // Yield
                    await Task.yield()
                }
            } catch {
                self.updateStatus { s in
                    s.phase = .failed
                    s.errorMessage = error.localizedDescription
                }
            }
        }

        setVerificationTask(task)
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
        getVerificationTask()?.cancel()
        updateStatus { s in
            s.phase = .idle
        }
        lock.lock()
        runner = nil
        lock.unlock()
    }
}
