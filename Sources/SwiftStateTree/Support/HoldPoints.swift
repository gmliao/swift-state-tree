// Sources/SwiftStateTree/Support/HoldPoints.swift
//
// Named hold points for forced-interleaving tests: a test holds the code at the `await` where a
// race can happen, issues the competing call, then lets it go. No timing involved.

import Foundation

/// Two optional hooks per instance, called at named points: the async hold hook, then the
/// resumed hook on the caller's executor (`installResumed`). A no-op (two `nil` checks, no
/// suspension, no executor hop) unless a test installs one.
///
/// In the owning type:
/// ```swift
/// enum HoldPoint: Hashable, Sendable { case afterLandLookup }
/// var holds = HoldPoints<HoldPoint>()
/// ...
/// await holds.at(.afterLandLookup)
/// ```
package struct HoldPoints<Point: Hashable & Sendable>: Sendable {
    private var hook: (@Sendable (Point) async -> Void)?
    private var resumedHook: (@Sendable (Point, isolated (any Actor)?) -> Void)?

    package init() {}

    /// Installs (or, with `nil`, removes) the hook. Tests only.
    package mutating func install(_ hook: (@Sendable (Point) async -> Void)?) {
        self.hook = hook
    }

    /// Installs (or, with `nil`, removes) the resumed hook. Tests only.
    ///
    /// It runs synchronously on the caller's executor right after `at`'s hook returned, in the
    /// segment that resumes there. A job it starts on that executor (a `Task` that captures the
    /// `isolated` parameter) runs only after that segment ends, at the caller's next suspension:
    /// so a test can read what the code did between the hold and its next `await`, which a read
    /// issued from the hook's own task can't order (the hook is nonisolated, and its return
    /// enqueues the caller's resumption from another thread).
    package mutating func installResumed(_ hook: (@Sendable (Point, isolated (any Actor)?) -> Void)?) {
        resumedHook = hook
    }

    /// Awaits the hook at `point`, if one is installed.
    ///
    /// Runs on the caller's executor (`isolation`), and with nothing installed it returns without
    /// suspending: an actor's code before and after `await holds.at(...)` stays one synchronous
    /// segment, so no other job of that actor runs in between. A plain nonisolated `async`
    /// method would hop off the actor here even with no hook, and open a reentrancy window at
    /// every hold point in production.
    package func at(_ point: Point, isolation: isolated (any Actor)? = #isolation) async {
        if let hook { await hook(point) }
        resumedHook?(point, isolation)
    }
}

/// Test side of `HoldPoints`: routes each point to the closure registered for it, so one
/// installed hook serves several points, and a hold can apply to the n-th arrival only. Points
/// with nothing registered pass straight through.
///
/// ```swift
/// let holds = HoldRegistry<LandKeeperHoldPoint>()
/// holds.on(.join) { await gate.arrive() }
/// await keeper.installHolds(holds.hook)
/// ```
package final class HoldRegistry<Point: Hashable & Sendable>: @unchecked Sendable {
    private struct Entry {
        let arrival: Int?
        let body: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var entries: [Point: [Entry]] = [:]
    private var arrivals: [Point: Int] = [:]

    package init() {}

    /// Runs `body` at `point`: on every arrival, or only on the `arrival`-th (1-based).
    @discardableResult
    package func on(_ point: Point, arrival: Int? = nil, _ body: @escaping @Sendable () async -> Void) -> Self {
        lock.withLock { entries[point, default: []].append(Entry(arrival: arrival, body: body)) }
        return self
    }

    /// Removes every closure registered at `point`; later arrivals pass through.
    package func clear(_ point: Point) {
        lock.withLock { entries[point] = nil }
    }

    /// Arrivals at `point` so far, held or not.
    package func arrivalCount(at point: Point) -> Int {
        lock.withLock { arrivals[point, default: 0] }
    }

    /// A hook that runs `body` at `point` only: `installHolds(HoldRegistry.at(.join) { ... })`.
    package static func at(_ point: Point, _ body: @escaping @Sendable () async -> Void) -> @Sendable (Point) async -> Void {
        HoldRegistry().on(point, body).hook
    }

    /// The hook to install with the owning type's `installHolds`.
    package var hook: @Sendable (Point) async -> Void {
        { [self] point in await self.arrive(at: point) }
    }

    private func arrive(at point: Point) async {
        let bodies: [@Sendable () async -> Void] = lock.withLock {
            let n = arrivals[point, default: 0] + 1
            arrivals[point] = n
            return (entries[point] ?? []).filter { $0.arrival == nil || $0.arrival == n }.map(\.body)
        }
        for body in bodies { await body() }
    }
}
