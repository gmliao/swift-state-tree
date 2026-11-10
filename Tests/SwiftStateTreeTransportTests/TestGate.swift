// Tests/SwiftStateTreeTransportTests/TestGate.swift
//
// A gate for forced-interleaving tests: code under test awaits `arrive()` at the point where a
// race can happen, the test sees the arrival, issues the competing calls, then opens the gate.
// Deterministic, unlike sleeping and hoping the scheduler interleaves.

import Foundation

/// How long a wait for an event may take before the test fails as hung (#447).
///
/// A hang guard, not a timing assumption: the waits below return as soon as their event
/// happens, so the bound only matters when the event never comes. It sits far past any
/// scheduling stall a loaded runner produces: a 5 s bound failed tests whose order held, beside
/// CPU-heavy tests on a 4-core runner. A wait that checks something *doesn't* happen must not use
/// it; it states its own short bound instead.
let testHangBound: Duration = .seconds(60)

final class TestGate: @unchecked Sendable {
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

    /// Suspends until `open()`; returns at once if the gate is open already.
    func arrive() async {
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
    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }

    /// Number of `arrive()` calls so far.
    var arrivalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return arrivals
    }

    /// Waits until `count` arrivals happened; returns whether they did. Resumed by the arrival
    /// itself, not by polling; `false` only after `testHangBound`, when the code never arrived.
    @discardableResult
    func waitForArrivals(_ count: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if arrivals >= count {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            let id = nextWaiterID
            nextWaiterID += 1
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
}

/// Polls `condition` every 5 ms until it holds, for at most `testHangBound`; returns its final
/// value. For state no event reports; a gate's arrival uses `waitForArrivals`.
@discardableResult
func pollUntil(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + testHangBound
    // wall-clock: condition poll with a 60 s hang bound; callers are counted by the poll-helper rule
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
