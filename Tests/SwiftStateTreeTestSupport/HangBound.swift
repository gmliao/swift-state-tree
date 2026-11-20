// Tests/SwiftStateTreeTestSupport/HangBound.swift
//
// A bound for a test's wait on an event that a regression may never send (#458): a suite's
// `.timeLimit` reports a test but doesn't end a wait that never resumes.

import SwiftStateTree

/// Runs `wait` under `testHangBound`: `true` when it returned on its own, `false` when the bound
/// ran out first. `wait` must return when its task is cancelled (the bound cancels it), as the
/// keeper's and the router's test waits do.
package func withinHangBound(_ wait: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await wait()
            return true
        }
        group.addTask {
            try? await safeTaskSleep(for: testHangBound)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
