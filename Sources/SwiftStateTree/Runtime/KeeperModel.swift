// Sources/SwiftStateTree/Runtime/KeeperModel.swift
//
// The keeper's plain state (#700 K1b-4): every field a turn reads or writes, and nothing that
// holds a reference, a closure or an existential. `@PlainData` checks that at compile time.

import Logging
import SwiftStateTurns

/// The keeper's machine: the land's state and the keeper's plain bookkeeping. The keeper holds
/// it as `model`; field names are the ones the keeper's stored properties had.
@PlainData
struct KeeperModel<State: StateNodeProtocol> {
    init() {}
}

/// What a keeper is fixed with at init (#700 K1b-4): its land's definition, its own
/// configuration and the outside world's services. Read-only, so the keeper holds it as a
/// `nonisolated let`.
struct KeeperBehavior<State: StateNodeProtocol>: Sendable {
    let definition: LandDefinition<State>
    let config: KeeperConfig
    /// The land's services, without a `DeterministicRngService`: the land's generator is
    /// `model.landRandom`, and contexts get it per handler call (`withHandlerStep`).
    let services: LandServices
    /// The land's services value, which its `Resolver` values get (#769 §3.4): the one the typed
    /// entry point gave, `NoServices()` for a land without services, or nil for a land that
    /// declares services and was given none (its initialization fails).
    let resolverServices: (any Sendable)?
    /// The decoders a replay reads recorded client payloads with (#700 K1a, K1-Q6 (i)). A live
    /// keeper doesn't use them.
    let payloadDecoders: RecordPayloadDecoders
    let logger: Logger
}

/// The keeper's own configuration, fixed at init. Internal: the public `LandConfig` is the DSL's
/// configuration of the land, and holds none of these.
struct KeeperConfig: Sendable {
    let autoStartLoops: Bool
    /// Delay each loop's first iteration by `LandLoopPhase.offset` (see `loopPhaseOffset`).
    let enableLoopPhaseOffset: Bool
    let enableLiveStateHashRecording: Bool
    let reevaluationOutputMode: ReevaluationOutputMode
    let mode: LandMode
    /// Actual land instance ID (e.g., "counter:550e8400-...")
    /// This is different from definition.id which is just the land type (e.g., "counter")
    let actualLandID: String?
    /// The seed `model.landRandom` started from: a caller-registered `DeterministicRngService`'s
    /// seed, else derived from the land ID. The record header holds it.
    let landRandomSeed: UInt64
    // The public system IDs from LandContext.
    let systemPlayerID: PlayerID = LandContext.systemPlayerID
    let systemClientID: ClientID = LandContext.systemClientID
    let systemSessionID: SessionID = LandContext.systemSessionID
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
