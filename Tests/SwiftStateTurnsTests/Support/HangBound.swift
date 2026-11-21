import Foundation
import SwiftStateTree
import SwiftStateTurns
import Testing

/// The bound on a test's own wait for an event that a regression may never bring: the same 60 s
/// as `testHangBound` in SwiftStateTreeTestSupport, which this target doesn't link. A suite's
/// `.timeLimit` reports a slow test but can't end a wait that ignores cancellation
/// (Notes/solutions/2026-11-20-a-time-limit-does-not-end-a-wait-that-never-resumes.md), so every
/// wait the follow-up cases make from the test's own task goes through one of the functions
/// below. It costs nothing when the event comes: each wait ends on the event, not on a poll of
/// the bound.
let turnTestHangBound: Duration = .seconds(60)

/// `body`'s result, or nil when the bound runs out first or the test's task is cancelled (its
/// time limit). `body` must return when its task is cancelled.
func withinTurnHangBound<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await safeTaskSleep(for: turnTestHangBound)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

extension Fixture {
    /// The test's own wait for `name`: true once it is open; false, with an issue recorded, when
    /// the hang bound runs out or the test is cancelled first. Effects and checks keep `wait` and
    /// `waitUnlessCancelled`: a test may end with one of them parked at a gate on purpose.
    @discardableResult
    func reach(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let opened = await withinTurnHangBound { await self.waitUnlessCancelled(name) } ?? false
        if !opened { Issue.record("\"\(name)\" never opened", sourceLocation: sourceLocation) }
        return opened
    }
}

/// `task`'s value. The task is cancelled when the hang bound runs out or the test is cancelled,
/// so a quiescence wait a regression never wakes returns false (its cancellation answer) instead
/// of parking the test. `task` must return when cancelled.
func settled<T: Sendable>(_ task: Task<T, Never>) async -> T {
    let timer = Task {
        guard (try? await safeTaskSleep(for: turnTestHangBound)) != nil else { return }
        task.cancel()
    }
    defer { timer.cancel() }
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// A wait that answers false when cancelled (a quiescence wait), under the hang bound: false when
/// the bound runs out first.
func bounded(_ wait: @escaping @Sendable () async -> Bool) async -> Bool {
    await withinTurnHangBound(wait) ?? false
}
