// Sources/SwiftStateTree/Runtime/KeeperSideStore.swift
//
// Where a core-driven keeper keeps its turn side between steps (#700 K2-1, plan
// `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` §4.5). Part of `KeeperTurnSide`
// outlives a step: the failure table, the waiters, the pending follow-up sync turn, the destroy
// ticket, the per-player services, the test waiters and the attached transport. A core step gets
// only the model, the turn and the input, so a side built fresh in each step would lose them.
// Until K2-2 moves each field to its home (replies, outputs, the binding token, the behavior),
// the core reaches the side through this box, which the behavior carries.
//
// This is a stated exception to the behavior's advice (values and functions), as the re-entry
// sentinel is. It is bounded the same way: one box per core, used on that core's executor only,
// and borrowed by one step at a time, for one body call.

import Foundation

/// A core's turn side, borrowed `inout` by each step's body call (`withSide`), as the keeper's
/// `withTurn` borrows its stored `turnSide`.
///
/// Confinement is checked, not only stated: `withSide` asserts that it runs on the owner's
/// executor before the borrow. That is why the class can be `@unchecked Sendable` with no lock:
/// it travels in the `Sendable` behavior, but is read and written only on one executor.
final class KeeperSideStore: @unchecked Sendable {
    private var side: KeeperTurnSide
    /// The actor that owns the core this box serves, set once, right after the owner's init.
    /// Weak: the owner holds the core, which holds the behavior, which holds this box.
    private weak var owner: (any Actor)?
    /// Whether a step holds the borrow; a nested borrow is a bug.
    private var borrowed = false

    /// Whether an output for `.land` before the owner started that key stops a debug build;
    /// the test that pins the counted drop turns it off.
    var assertsOnUnstartedLandKey = true

    /// A box for one core. `side` is the core's own fresh side, never the keeper's `turnSide`.
    init(side: KeeperTurnSide) {
        self.side = side
    }

    /// Binds the box to the actor whose executor runs the core's steps. Once.
    func bind(to owner: any Actor) {
        precondition(self.owner == nil, "KeeperSideStore: bound twice")
        self.owner = owner
    }

    /// Stops unless the caller runs on the owner's executor. A core step calls it once at its
    /// entry (`KeeperModel.step`), so where the step runs is a property of the frame, not an
    /// assumption about the core's adopter; `withSide` checks it again per borrow.
    func preconditionOnOwner() {
        guard let owner else { preconditionFailure("KeeperSideStore: used before bind(to:)") }
        owner.preconditionIsolated("KeeperSideStore: a core step off its owner's executor")
    }

    /// Runs `body` with the side borrowed `inout`. Only on the owner's executor, and never
    /// nested: the borrow ends when `body` returns, and `body` can't keep it.
    func withSide<R>(_ body: (inout KeeperTurnSide) throws -> R) rethrows -> R {
        guard let owner else { preconditionFailure("KeeperSideStore: used before bind(to:)") }
        owner.preconditionIsolated("KeeperSideStore: a side borrowed off its core's executor")
        precondition(!borrowed, "KeeperSideStore: a nested borrow")
        borrowed = true
        defer { borrowed = false }
        return try body(&side)
    }
}
