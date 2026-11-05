// Tests/SwiftStateTreeTransportTests/TestGate.swift
//
// A gate for forced-interleaving tests: code under test awaits `arrive()` at the point where a
// race can happen, the test sees the arrival, issues the competing calls, then opens the gate.
// Deterministic, unlike sleeping and hoping the scheduler interleaves.

import Foundation

final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until `open()`; returns at once if the gate is open already.
    func arrive() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivals += 1
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
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

    /// Waits until `count` arrivals happened (or 5 s passed); returns whether they did.
    @discardableResult
    func waitForArrivals(_ count: Int) async -> Bool {
        await pollUntil { self.arrivalCount >= count }
    }
}

/// Polls `condition` every 5 ms for up to 5 s; returns its final value.
@discardableResult
func pollUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
