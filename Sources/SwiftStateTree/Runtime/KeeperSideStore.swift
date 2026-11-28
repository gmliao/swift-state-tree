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
        var side = side
        side.coreInputReplies.onCore = true
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

/// What #700 K2-1's differential compares from a model and its side: a copy of the model, the
/// action tables' violations, and the side's per-player service generations.
struct KeeperDifferentialRead<State: StateNodeProtocol>: Sendable {
    let model: KeeperModel<State>
    let violations: [String]
    let serviceGenerations: [PlayerID: UInt64]
    let coreWaitsLeft: Int
    /// Whether the destroy slot holds a ticket, and the last issued ticket (tests only).
    let holdsDestroyTicket: Bool
    let lastDestroyTicket: DestroyTicket?
    /// The drain flag's failure, when the land failed.
    let failure: LandFailure?
    /// The events still in the side's collector (a keeper's tick flushes its own), and the
    /// lease's count of outputs that found nothing lent.
    let collectedEventSequences: [Int64]
    let unlentCount: Int
    /// The side's failure table's IDs, the drain flag, the transport-failure mailbox and the
    /// pending follow-up sync turn (Review round 1 on #938: state a diverging core could change).
    let failureIDs: [String]
    let isDraining: Bool
    let mailboxFailure: LandFailure?
    let pendingSyncTurnAfterTurn: String

    init(model: KeeperModel<State>, side: KeeperTurnSide) {
        self.model = model
        violations = model.actionTableViolations(side)
        serviceGenerations = side.playerServices.mapValues(\.generation.rawValue)
        // Every core table a step can leave a caller or an effect in: the input-turn waits, the
        // dropped ones, the job slots' waits and ready replies, the job lane, the held intakes,
        // and the model's barrier waits (the freeze's and the initialization's: Review on #966;
        // the stop's two lists: Review r2 on #969).
        let replies = side.coreInputReplies
        coreWaitsLeft = replies.waits.count + replies.dropped.count + replies.slots.waits.count + replies.slots.ready.count
            + replies.jobStarts.count + replies.jobReleases.count + replies.heldWhileFrozen.count
            + model.coreBarrierWaits.freeze.values.reduce(0) { $0 + $1.count } + model.coreBarrierWaits.initialized.count
            + model.coreBarrierWaits.drained.count + model.coreBarrierWaits.stopsAwaitingInitialization.count
        holdsDestroyTicket = side.destroyTicket != nil
        lastDestroyTicket = side.lastDestroyTicketForTesting
        failure = side.failure
        collectedEventSequences = side.sharedCollector.emittedEvents.map(\.sequence)
        unlentCount = side.sharedSequenceLease.unlentCount
        failureIDs = side.failures.keys.map { "\($0)" }.sorted()
        isDraining = side.isDraining
        mailboxFailure = side.sharedTransportFailure.failure
        pendingSyncTurnAfterTurn = side.pendingSyncTurnAfterTurn.map { "\($0)" } ?? "-"
    }
}

extension KeeperSideStore {
    /// The land's failure and drain flag, for a freeze answer's closed-first rule (#730).
    var debugDrainLandEnd: DebugDrainLandEnd {
        withSide { side in DebugDrainLandEnd(failure: side.failure, draining: side.isDraining) }
    }
}
