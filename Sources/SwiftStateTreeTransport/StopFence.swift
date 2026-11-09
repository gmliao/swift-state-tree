// Sources/SwiftStateTreeTransport/StopFence.swift
//
// The fence that keeps late work off a shut-down event loop group (#351).

import Atomics
import SwiftStateTree

/// Guards every hand-off to an event loop from outside it, so that nothing is submitted to an
/// event loop group after it was shut down.
///
/// Work that outlives a shutdown deadline (a land whose destroy was abandoned, a disconnect still
/// in flight, an upgrade whose auth finished late) can still try to send, close or complete a
/// promise. Each of those hand-offs runs through `submit(_:)`; the shutdown calls `stop(cap:)`
/// before it shuts the group down.
///
/// Lock-free on the hand-off path (the measured send path): a caller increments `inFlight`,
/// loads `stopped`, submits only if it is unset, then decrements. `stop` stores `stopped`, then
/// waits for `inFlight` to reach 0. With sequentially consistent ordering, a caller that loaded
/// `stopped` as unset incremented `inFlight` before the store, so `stop` waits for it; a caller
/// that increments after the store loads it set and drops. Two rules keep that true:
/// - The body of `submit` must not suspend: only a synchronous enqueue (`eventLoop.execute`, a
///   promise completion), never an `await`, or `stop` would wait on whatever that awaits.
/// - `stop` waits at most `cap`, then logs the count still in flight and returns, so a caller
///   that was descheduled inside its body can't hold the shutdown.
package final class StopFence: Sendable {
    private let stopped = ManagedAtomic<Bool>(false)
    private let inFlight = ManagedAtomic<Int>(0)
    private let dropped = ManagedAtomic<Int>(0)

    package init() {}

    /// Runs `body` (a synchronous hand-off to an event loop) unless the fence is stopped.
    /// Returns whether it ran; a dropped call is counted.
    @discardableResult
    package func submit(_ body: () -> Void) -> Bool {
        inFlight.wrappingIncrement(ordering: .sequentiallyConsistent)
        defer { inFlight.wrappingDecrement(ordering: .sequentiallyConsistent) }
        guard !stopped.load(ordering: .sequentiallyConsistent) else {
            dropped.wrappingIncrement(ordering: .relaxed)
            return false
        }
        body()
        return true
    }

    /// Stops the fence, then waits (at most `cap`) for the hand-offs already past the check.
    /// - Returns: the hand-offs still in flight when the cap ran out (0 when all finished).
    @discardableResult
    package func stop(cap: Duration = .milliseconds(100)) async -> Int {
        stopped.store(true, ordering: .sequentiallyConsistent)
        let deadline = ContinuousClock.now + cap
        while true {
            let remaining = inFlight.load(ordering: .sequentiallyConsistent)
            if remaining == 0 { return 0 }
            if ContinuousClock.now >= deadline { return remaining }
            await Task.yield()
        }
    }

    package var isStopped: Bool { stopped.load(ordering: .sequentiallyConsistent) }

    /// Hand-offs dropped because the fence was stopped.
    package var droppedCount: Int { dropped.load(ordering: .relaxed) }
}
