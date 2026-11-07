import Foundation

public struct ReevaluationRecorderService: Sendable {
    public let recorder: ReevaluationRecorder
    /// The keeper's recorder submissions still on their way (`ReevaluationRecordSaver` awaits
    /// them before saving).
    public let submissions: ReevaluationSubmissionTracker

    public init(recorder: ReevaluationRecorder, submissions: ReevaluationSubmissionTracker = ReevaluationSubmissionTracker()) {
        self.recorder = recorder
        self.submissions = submissions
    }
}

/// Counts a keeper's recorder submissions (tasks that apply a record to the recorder in order)
/// and waits for them with a deadline, so a stuck submission can't hang shutdown.
public final class ReevaluationSubmissionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var tail: Task<Void, Never>?

    public init() {}

    /// Wraps `apply` in a submission that runs after every earlier one.
    @discardableResult
    package func submit(_ apply: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        pending += 1
        let submission = Task { [self] in
            await previous?.value
            await apply()
            lock.withLock { pending -= 1 }
        }
        tail = submission
        return submission
    }

    /// Submissions not yet applied.
    public var pendingCount: Int { lock.withLock { pending } }

    /// Waits until every submission so far is applied, or `deadline` passes; returns how many
    /// are still pending (0 when all were applied).
    public func drain(within deadline: Duration) async -> Int {
        guard let last = lock.withLock({ tail }) else { return 0 }
        let resume = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resume.set(continuation)
            Task { await last.value; resume.fire() }
            Task { try? await safeTaskSleep(for: deadline); resume.fire() }
        }
        return pendingCount
    }

    /// Waits for every submission so far, without a deadline (tests).
    public func waitForAll() async {
        await lock.withLock({ tail })?.value
    }
}

/// Resumes a continuation once, from whichever caller comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        fired = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
