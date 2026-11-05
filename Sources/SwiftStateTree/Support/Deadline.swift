// Sources/SwiftStateTree/Support/Deadline.swift
//
// A deadline for awaits that may never return (a held test whose code under test forgot a
// resume). A hang burns the CI job's timeout and names nothing; racing the await against a
// deadline turns it into a failure of the step that hung.
//
// Follow-up: this is test support kept in Sources (package access) only because there is no
// shared test-support target; move it, with `TestGate` (SwiftStateTreeTransportTests), into one
// once a second shared helper needs it.

import Foundation

/// How a `raceDeadline` ended.
package enum DeadlineOutcome<Value: Sendable>: Sendable {
    /// `work` returned or threw first.
    case finished(Result<Value, any Error>)
    /// The deadline passed first. `work`'s task is left running (leaked): nothing can stop a
    /// task suspended on a continuation nobody resumes.
    case timedOut
}

/// Runs `work` in an unstructured task and returns whichever comes first: its result or the
/// deadline. A task group can't do this, since it waits for its children before returning.
///
/// Cancelling the caller neither cancels `work` nor makes the race return early: both tasks
/// are unstructured, so the race still waits for `work` or the deadline, whichever comes first.
///
/// Tests only; callers record a failure naming the step on `.timedOut`.
package func raceDeadline<Value: Sendable>(
    _ deadline: Duration,
    _ work: @escaping @Sendable () async throws -> Value
) async -> DeadlineOutcome<Value> {
    let race = DeadlineRace<Value>()
    return await withCheckedContinuation { continuation in
        race.install(continuation)
        let timer = Task {
            // A cancelled sleep means the work finished first.
            guard (try? await safeTaskSleep(for: deadline)) != nil else { return }
            race.finish(.timedOut)
        }
        race.setTimer(timer)
        Task {
            let result: Result<Value, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            race.finish(.finished(result))
        }
    }
}

/// The continuation of one race, resumed exactly once by whichever side finishes first.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        let finished = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            self.timer = timer
            return false
        }
        if finished { timer.cancel() }
    }

    func finish(_ outcome: DeadlineOutcome<Value>) {
        let (continuation, timer) = lock.withLock { () -> (CheckedContinuation<DeadlineOutcome<Value>, Never>?, Task<Void, Never>?) in
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return (self.continuation, self.timer)
        }
        guard let continuation else { return }
        timer?.cancel()
        continuation.resume(returning: outcome)
    }
}
