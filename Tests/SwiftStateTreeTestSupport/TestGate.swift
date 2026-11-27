// Tests/SwiftStateTreeTestSupport/TestGate.swift
//
// A gate for forced-interleaving tests: code under test awaits `arrive()` at the point where a
// race can happen, the test sees the arrival, issues the competing calls, then opens the gate.
// Deterministic, unlike sleeping and hoping the scheduler interleaves.

import Foundation
import SwiftStateTreeTransport

/// How long a wait for an event may take before the test fails as hung (#447).
///
/// A hang guard, not a timing assumption: the waits below return as soon as their event
/// happens, so the bound only matters when the event never comes. It sits far past any
/// scheduling stall a loaded runner produces: a 5 s bound failed tests whose order held, beside
/// CPU-heavy tests on a 4-core runner. A wait that checks something *doesn't* happen must not use
/// it; it states its own short bound instead.
package let testHangBound: Duration = .seconds(60)

/// A freeze, settle or auto-resume deadline for tests that hold work while frozen: far above any
/// runner stall, so only the test's release ends the wait. The suite's time limit bounds a hang.
/// A test of the deadline itself sets its own short value (#904, #928).
package let freezeWithoutDeadline: Duration = .seconds(3600)

/// Whether the test support (and so the package) was built in debug. A test whose ordering
/// depends on a wait probe that returns at once outside DEBUG builds gates on it
/// (`.enabled(if: isDebugBuild, …)`), so a release run reports it skipped. A test that only
/// reads a DEBUG-only observation puts `#if DEBUG` around that capture and its expectations
/// instead, so release keeps the rest of its coverage (#748).
#if DEBUG
package let isDebugBuild = true
#else
package let isDebugBuild = false
#endif

package final class TestGate: @unchecked Sendable {
    private struct ArrivalWaiter {
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
        var timer: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [Int: ArrivalWaiter] = [:]
    private var nextWaiterID = 0
    /// Waiters cancelled before they registered (the handler ran first).
    private var cancelledWaiterIDs: Set<Int> = []

    package init() {}

    /// Suspends until `open()`; returns at once if the gate is open already.
    package func arrive() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivals += 1
            let reached = takeReachedArrivalWaiters()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
            for waiter in reached {
                waiter.timer?.cancel()
                waiter.continuation.resume(returning: true)
            }
        }
    }

    /// Lets every current and future arrival through.
    package func open() {
        lock.lock()
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }

    /// Number of `arrive()` calls so far.
    package var arrivalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return arrivals
    }

    /// Number of `waitForArrivals` calls still waiting.
    package var arrivalWaiterCount: Int {
        lock.withLock { arrivalWaiters.count }
    }

    /// Waits until `count` arrivals happened; returns whether they did. Resumed by the arrival
    /// itself, not by polling; `false` when the waiting task is cancelled, or after
    /// `testHangBound`, when the code never arrived.
    @discardableResult
    package func waitForArrivals(_ count: Int) async -> Bool {
        let id = lock.withLock { () -> Int in
            defer { nextWaiterID += 1 }
            return nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if arrivals >= count {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                if cancelledWaiterIDs.remove(id) != nil {
                    // Cancelled before it waited: the handler found nothing to end.
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                arrivalWaiters[id] = ArrivalWaiter(count: count, continuation: continuation, timer: nil)
                lock.unlock()
                let timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: testHangBound)) != nil else { return }
                    self?.expireArrivalWaiter(id)
                }
                lock.lock()
                if arrivalWaiters[id] != nil {
                    arrivalWaiters[id]?.timer = timer
                    lock.unlock()
                } else {
                    // Resumed between the insert and here: the timer has nothing left to end.
                    lock.unlock()
                    timer.cancel()
                }
            }
        } onCancel: {
            cancelArrivalWaiter(id)
        }
    }

    /// Removes and returns the waiters whose count is reached. Called with `lock` held.
    private func takeReachedArrivalWaiters() -> [ArrivalWaiter] {
        let reached = arrivalWaiters.filter { $0.value.count <= arrivals }
        for id in reached.keys { arrivalWaiters[id] = nil }
        return Array(reached.values)
    }

    private func expireArrivalWaiter(_ id: Int) {
        lock.lock()
        let waiter = arrivalWaiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.continuation.resume(returning: false)
    }

    /// Ends a cancelled wait at once, instead of leaving it until an arrival or the hang bound.
    private func cancelArrivalWaiter(_ id: Int) {
        lock.lock()
        let waiter = arrivalWaiters.removeValue(forKey: id)
        if waiter == nil { cancelledWaiterIDs.insert(id) }
        lock.unlock()
        waiter?.timer?.cancel()
        waiter?.continuation.resume(returning: false)
    }
}

extension WebSocketTransport {
    /// Holds each delayed close at its bound (`closeSessionAfterQueuedFrames`'s timeout, 1 s by
    /// default) before the close checks the session, until the returned gate opens; the gate's
    /// arrivals count the bounds that ran out. A test that holds a send across several awaits
    /// otherwise races that bound in real time, and loses it on a loaded runner (#647). Open the
    /// gate in a `defer` right after this call: a held bound's task waits for it.
    package func holdBoundClosesForTesting() -> TestGate {
        let bound = TestGate()
        setDelayedCloseForTesting { stage in
            if case .willCheck(.bound) = stage { await bound.arrive() }
        }
        return bound
    }
}

/// Polls `condition` every 5 ms until it holds, for at most `testHangBound`; returns its final
/// value. For state no event reports; a gate's arrival uses `waitForArrivals`.
@discardableResult
package func pollUntil(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + testHangBound
    // wall-clock: condition poll with a 60 s hang bound; callers are counted by the poll-helper rule
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
