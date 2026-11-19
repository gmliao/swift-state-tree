// Tests/SwiftStateTreeTestSupport/EventLog.swift
//
// An in-memory log of named events that a test can wait on: each append resumes the waits it
// satisfies, so a test waits for the event itself, not for a deadline (#458).

import Foundation

/// Events in the order they were appended; `waitFor` returns when the log meets a condition.
package final class EventLog: @unchecked Sendable {
    private struct Waiter {
        let condition: @Sendable ([String]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var stored: [String] = []
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiterID = 0
    /// Waits whose hang bound ran out before they registered.
    private var expiredWaiterIDs: Set<Int> = []

    package init() {}

    /// Every event so far, in order.
    package var events: [String] { lock.withLock { stored } }

    /// Appends `event` and resumes every wait whose condition the log now meets.
    package func append(_ event: String) {
        let ready: [CheckedContinuation<Bool, Never>] = lock.withLock {
            stored.append(event)
            let log = stored
            let reached = waiters.filter { $0.value.condition(log) }
            for id in reached.keys { waiters.removeValue(forKey: id) }
            return reached.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume(returning: true) }
    }

    /// Waits until the log meets `condition`; resumed by `append`, not by polling. `false` after
    /// `testHangBound`, when the event never comes.
    @discardableResult
    package func waitFor(_ condition: @escaping @Sendable ([String]) -> Bool) async -> Bool {
        let id = lock.withLock { () -> Int in
            defer { nextWaiterID += 1 }
            return nextWaiterID
        }
        let hangGuard = Task { [weak self] in
            guard (try? await Task.sleep(for: testHangBound)) != nil else { return }
            self?.expire(id)
        }
        defer { hangGuard.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if condition(stored) {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            if expiredWaiterIDs.remove(id) != nil {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            waiters[id] = Waiter(condition: condition, continuation: continuation)
            lock.unlock()
        }
    }

    /// `waitFor` an event equal to `event`.
    @discardableResult
    package func waitFor(_ event: String) async -> Bool {
        await waitFor { $0.contains(event) }
    }

    private func expire(_ id: Int) {
        let waiter: Waiter? = lock.withLock {
            guard let waiter = waiters.removeValue(forKey: id) else {
                expiredWaiterIDs.insert(id)
                return nil
            }
            return waiter
        }
        waiter?.continuation.resume(returning: false)
    }
}
