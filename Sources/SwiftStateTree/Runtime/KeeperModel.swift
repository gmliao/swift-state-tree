// Sources/SwiftStateTree/Runtime/KeeperModel.swift
//
// The keeper's plain state (#700 K1b-4): every field a turn reads or writes, and nothing that
// holds a reference, a closure or an existential. `@PlainData` checks that at compile time.

import SwiftStateTurns

/// The keeper's machine: the land's state and the keeper's plain bookkeeping. The keeper holds
/// it as `model`; field names are the ones the keeper's stored properties had.
@PlainData
struct KeeperModel<State: StateNodeProtocol> {
    init() {}
}

// MARK: - The keeper's nested types the model holds (were private to `LandKeeper.swift`)

/// The keeper's sync binding as a generation: each bind or rebind issues a new ticket, and a
/// ticket from an earlier binding is never current again (also after A → B → A).
@PlainData
struct KeeperSyncBinding: Sendable {
    private var table: GenerationTable<SyncBindingKey> = GenerationTable<SyncBindingKey>()
    private(set) var current: SyncTurnTicket

    init() { current = table.issue(.binding) }

    mutating func rebind() { current = table.issue(.binding) }

    func isCurrent(_ ticket: SyncTurnTicket) -> Bool { table.isCurrent(ticket) }
}

/// What an action captured at intake about its sender, checked when its resolvers' result
/// is delivered (`LandKeeper.deliverResolvedAction`).
@PlainData
struct KeeperActionTicket: Sendable {
    /// The sender's entry generation at intake; `nil` when the player had no entry (direct
    /// callers that send before or without a join) or the sender is exempt (the system
    /// player or client).
    let entryGeneration: Epoch?
}

/// An action whose resolvers run in their own task, keyed by its sequence: the part the
/// model keeps (#700 K1b-2). The task, the abandonment and the caller's cancellation flag are
/// in the keeper's `actionJobTasks`. Generic because `item` is a type nested in the generic
/// keeper.
@PlainData
struct KeeperActionJob<State: StateNodeProtocol>: Sendable {
    /// The action as taken in; its resolver outputs are filled in at delivery.
    let item: LandKeeper<State>.PendingActionItem
    let ticket: KeeperActionTicket
    let input: String
    /// The completion ran; the job stays registered only while its abandoned resolvers run.
    var completed: Bool = false
    /// Cancelled by the keeper (the sender's entry ended, or the land is draining): its slot
    /// already holds the delivery checks' rejection, and its completion only removes it.
    var cancelledByKeeper: Bool = false
}

/// The outcome of a job, kept from `submitAction` until `awaitActionResult` reads it. It's
/// created in the intake's segment, so a reader that arrives after the completion still finds
/// it. A failure is held by its ID in the keeper's failure table.
@PlainData
struct KeeperActionSlot: Sendable {
    var result: InputResult?
}
