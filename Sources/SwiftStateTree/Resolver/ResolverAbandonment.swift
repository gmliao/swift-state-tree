// Sources/SwiftStateTree/Resolver/ResolverAbandonment.swift
//
// What a resolver group its caller stopped waiting for still costs (#364). Swift can't stop a
// task that ignores cancellation, so an abandoned group keeps running; what a bound can change
// is the accounting: which gauges and caps count the group, and when they let it go.
//
// Lock order, three deep: the deadline race's lock (`ResolverDeadlineRace.settle` runs
// `noteBegan` under it) → an abandonment's lock → the metrics' and the land counter's locks.
// The last two are leaf locks: nothing is called while either is held, no logging, no callback.

import Foundation

/// One resolver group's abandonment: its caller stopped waiting (the deadline, or a
/// cancellation) while the group's task still runs. The executor calls `noteBegan` and
/// `noteEnded`; each transition is one lock acquisition, and every gauge change comes from a
/// transition's result, so a gauge moves exactly once each way.
package final class ResolverAbandonment: @unchecked Sendable {
    /// Which resolver group: a land counts and caps its abandoned groups per kind.
    package enum Kind: String, CaseIterable, Sendable {
        case action
        case canJoin
        case onJoin
        case onLeave
        case onInitialize
    }

    /// What `noteBegan` did.
    package enum Began: Sendable, Equatable {
        /// `running` → `abandoned`: the gauges went up.
        case began
        /// Already abandoned or ended: nothing changed.
        case none
    }

    /// What `noteEnded` did.
    package enum Ended: Sendable, Equatable {
        /// `abandoned` → `ended`: the gauges came down.
        case ended
        /// Never abandoned, or already ended: nothing changed.
        case none
    }

    private enum State {
        case running
        case abandoned
        case ended
    }

    /// `nil` for a group no land owns (the public `ResolverExecutor.executeResolvers`): it moves
    /// only the generic gauge.
    package let kind: Kind?
    private let lock = NSLock()
    private var state = State.running
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let metrics: ResolverDeadlineMetrics
    private let counter: LandAbandonmentCounter?
    /// Called once, after `.ended`.
    private let onEnded: (@Sendable () -> Void)?

    package init(
        kind: Kind?,
        counter: LandAbandonmentCounter?,
        metrics: ResolverDeadlineMetrics,
        onEnded: (@Sendable () -> Void)? = nil
    ) {
        self.kind = kind
        self.counter = counter
        self.metrics = metrics
        self.onEnded = onEnded
    }

    /// The caller stopped waiting while the group runs. Called inside the race's lock, when the
    /// deadline or the cancellation wins it.
    @discardableResult
    func noteBegan() -> Began {
        lock.withLock {
            guard state == .running else { return .none }
            state = .abandoned
            metrics.noteAbandonedBegan(kind)
            if let kind { counter?.increment(kind) }
            return .began
        }
    }

    /// The abandoned group's task ended. The gauges come down only from `.abandoned`, so a
    /// second call, or one for a group never abandoned, changes nothing.
    @discardableResult
    func noteEnded() -> Ended {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>]? in
            guard state == .abandoned else { return nil }
            state = .ended
            metrics.noteAbandonedEnded(kind)
            if let kind { counter?.decrement(kind) }
            defer { waiters = [] }
            return waiters
        }
        guard let toResume else { return .none }
        toResume.forEach { $0.resume() }
        onEnded?()
        return .ended
    }

    /// Abandoned and still running.
    package var isRunning: Bool {
        lock.withLock { state == .abandoned }
    }

    /// Returns once the abandoned task ended, or at once if it isn't running (tests).
    package func waitUntilEnded() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard state == .abandoned else { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// A land's abandoned resolver groups still running, per kind. The land's abandonments share
/// it and update it inside their transitions, so a group's end can't be counted before its
/// begin; the keeper reads it synchronously at intake.
///
/// A leaf lock (see the lock order above): nothing is called while it is held.
package final class LandAbandonmentCounter: @unchecked Sendable {
    private struct Waiter {
        let kind: ResolverAbandonment.Kind
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var counts: [ResolverAbandonment.Kind: Int] = [:]
    /// Tests only (`waitForCount`): resumed after the lock is released.
    private var waiters: [Waiter] = []

    package init() {}

    func increment(_ kind: ResolverAbandonment.Kind) {
        adjust(kind, by: 1)
    }

    func decrement(_ kind: ResolverAbandonment.Kind) {
        adjust(kind, by: -1)
    }

    private func adjust(_ kind: ResolverAbandonment.Kind, by delta: Int) {
        let reached = lock.withLock { () -> [Waiter] in
            counts[kind, default: 0] += delta
            guard !waiters.isEmpty else { return [] }
            let now = counts
            let reached = waiters.filter { now[$0.kind, default: 0] == $0.count }
            waiters.removeAll { now[$0.kind, default: 0] == $0.count }
            return reached
        }
        reached.forEach { $0.continuation.resume() }
    }

    /// The abandoned groups of `kind` still running.
    package func count(_ kind: ResolverAbandonment.Kind) -> Int {
        lock.withLock { counts[kind, default: 0] }
    }

    /// Returns once `count(kind) == count`, resumed by the transition that makes it so, or at
    /// once if it already is (tests).
    package func waitForCount(_ kind: ResolverAbandonment.Kind, _ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard counts[kind, default: 0] != count else { return true }
                waiters.append(Waiter(kind: kind, count: count, continuation: continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}
