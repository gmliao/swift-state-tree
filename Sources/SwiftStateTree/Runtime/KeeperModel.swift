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
    // Queues, jobs and results.
    var pendingItems: [LandKeeper<State>.PendingItem] = []
    /// Server inputs accepted during a debug freeze, in submission order: queued at the resume
    /// (`releaseServerInputsHeldWhileFrozen`), dropped if the land drains first.
    var serverInputsHeldWhileFrozen: [LandKeeper<State>.PendingItem] = []
    /// Queue elements visited by whole-queue scans (removals, replay's frame reads): the work a
    /// frame's replay does on the queue, for a bound on it in tests.
    var pendingItemScans: Int = 0
    /// The input-turn outcome of each waiting caller, kept until the turn's record is submitted.
    var inputTurnResults: [Int64: InputResult] = [:]
    /// Set when OnInitialize's resolvers timed out (#104): the land never initialized, every
    /// call that awaits the initialization throws it, and the drain skips the destroy handlers.
    var initializationFailure: FailureID?
    /// Mints failure IDs. Keeper-local: never reset, never restored from a record.
    var failureIDs: EpochCounter = EpochCounter()
    var actionJobs: [Int64: KeeperActionJob<State>] = [:]
    var actionSlots: [Int64: KeeperActionSlot] = [:]
    /// Tickless jobs whose in-flight work (`debugBeginWork` at intake) ends when their slot is
    /// filled, on whichever path fills it: so `debugFreeze` waits for their responses.
    var ticklessJobWork: Set<Int64> = []
    /// Tickless jobs delivered (appended) and not yet applied: the input turn that applies one
    /// fills its slot with the handler's outcome, after the turn's record is in.
    var ticklessJobTurns: Set<Int64> = []
    /// Jobs started so far (tests).
    var actionJobsStarted: Int = 0
    /// Tests: lookups that found no entry (`FailureTableMiss`).
    var failureTableMisses: Int = 0
    /// Tests: alignment violations the call sites logged.
    var alignmentViolations: Int = 0

    // Sync bindings and sync output.
    /// Bumped when the binding changes (`setTransport` with a transport, or the first requester
    /// bound): a follow-up or a delayed request armed under an older binding is stale, so
    /// A → B → A doesn't make an old request from A current again.
    var syncBinding: KeeperSyncBinding = KeeperSyncBinding()
    /// Interim (#700, #702): the follow-up slots below (this retry, the join-sync turn, the
    /// after-turn request) each keep the binding ticket they were armed under, and each job
    /// checks and retires only its own. That is TurnCore's request-per-key shape (#700), with the
    /// per-slot coalescing of a pending request per key (#702), kept by hand until the keeper's
    /// turns run on TurnCore. Known gap until then (#702 closes a superseded binding's follow-up
    /// at once): after a rebind, an older binding's retry still waiting on its writer outlives a
    /// teardown that reaches only the new binding's writer, and stays counted.
    ///
    /// A land without periodic sync: a sync-only turn waits for the writer to drain, at most one
    /// per binding. The binding generation it was armed under: a retry armed under an older binding
    /// neither blocks the current binding's nor clears its mark.
    var inTurnDrainRetryBinding: SyncTurnTicket?
    /// A sync-only turn for waiting joins is scheduled: the binding generation it was scheduled
    /// under (at most one per binding, as the drain retry).
    var joinSyncTurnBinding: SyncTurnTicket?
    /// The last recorded output's `observedTickId` and how many outputs were recorded after it
    /// (`ReevaluationRecordedSyncOutput.index`).
    var syncOutputIndexCursor: SyncOutputIndexCursor = SyncOutputIndexCursor(observedTickId: nil, count: 0)
    /// The kind of turn whose sync phase is running, for the sync outputs it records.
    var inTurnSyncTurnKind: ReevaluationRecordedSyncOutput.TurnKind = .tick
    /// Position of the next sync-stream entry (output or marker). Advanced only while the land
    /// records its sync stream (a recorder and in-turn sync), in the same synchronous segment as
    /// the entry it numbers; replay orders the stream by it.
    var syncStreamCounter: UInt64 = 0

    // Counters and flags.
    var stateHashUnavailableTotal: Int = 0
    /// Server inputs submitted and not yet applied (`SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND`).
    var serverInputsInFlight: Int = 0
    /// Server inputs refused because the in-flight cap was reached.
    var serverInputCapRejections: Int = 0
    /// The ordinal of a tickless land's last pass, 0 before its first (#563). Replay counts the
    /// same passes; a sync output records the value it read after (`afterPass`).
    var passOrdinal: Int64 = 0
    /// Syncs the sync loop folded into a coincident tick turn (diagnostics).
    var foldedSyncs: Int = 0
    /// Of `foldedSyncs`, those whose tick deadline had already passed at the fold. Mostly a race
    /// between the phase-locked tick and sync loops, not tick lateness (#232; diagnostics).
    var overdueFoldedSyncs: Int = 0
    /// Folded syncs whose tick turn started later than `coincidentSyncWindow` after the deadline
    /// the sync folded on (#232): counted when that turn starts (diagnostics).
    var lateFoldedSyncs: Int = 0
    /// Turns whose sync phase was deferred by writer back-pressure (diagnostics).
    var inTurnDeferredTurns: Int = 0
    /// Recorder submissions enqueued so far: a turn compares it with its start to know whether
    /// it recorded anything (a tickless sync-only turn then ends its turn record, #327).
    var recorderSubmissionCount: Int = 0
    /// Inputs `applyPendingItem` skipped because the destroy handlers had started (tests read it;
    /// every append path checks `isDraining`, so it stays 0).
    var inputsSkippedAfterDestroy: Int = 0
    /// Tick turns that ran their sync phase only for ready joins (no sync due by the cadence).
    var joinSyncTicks: Int = 0
    /// Inputs rejected by `rejectSenderIfSuperseded` so far.
    var supersededSenderRejections: Int = 0
    /// Next tick ID (0-based, increments with each tick) for deterministic replay.
    /// This represents the ID that will be assigned to the next tick execution.
    /// Using Int64 for long-running servers and replay compatibility.
    var nextTickId: Int64 = 0
    /// Last committed tick ID (the most recent tick that has completed execution).
    /// This represents the world state's current committed tick.
    /// Action/Event handlers should use this to bind to the committed world state.
    /// Initialized to -1 to indicate no ticks have been committed yet.
    var lastCommittedTickId: Int64 = -1
    /// Ticks with a handler running (`runTick`), possibly suspended in their awaits. A count,
    /// not a flag: a manual `stepTickOnce` can overlap a suspended tick, and the drain waits for
    /// all of them.
    var ticksInFlight: Int = 0
    /// Follow-ups armed and not yet run or retired: the writer-drain retry, the join-sync turn
    /// and a pending requested turn.
    var requestedSyncWork: Int = 0
    /// The destruction made its last call to the transport (`notifyTransportDestroyedAndRelease`).
    var destructionFinished: Bool = false
    /// `transport?.recordsInTurnSyncFolds`, read when the transport is attached.
    var transportRecordsFolds: Bool = false
    var didInitialize: Bool = false
    /// The next tick turn includes the sync phase: set when the sync loop fires within
    /// `coincidentSyncWindow` of the next tick (the coincident-sync rule).
    var inTurnSyncDue: Bool = false
    /// Tickless lands: an input drain is scheduled or running (one at a time).
    var inputDrainScheduled: Bool = false
    /// A join-only sync phase was deferred by back-pressure; cleared when a sync phase commits.
    var joinSyncWaitsForCommit: Bool = false
    /// Set by a tick land's forced shutdown before it waits for the tick in flight: `runTick`
    /// starts no tick from then on (#382).
    var shutdownRequested: Bool = false
    /// Whether a transport was ever attached: from the init's `transport:` argument or
    /// `setTransport`. A keeper that never had one accepts sync requests from the first adapter
    /// that asks (`bindSyncRequester`), and only from it.
    var hasHeldTransport: Bool = false
    /// Set when the drain starts the destroy handlers; `applyPendingItem` applies nothing after.
    var destroyHandlersStarted: Bool = false
    /// Set by the shutdown turn (#382). In re-evaluation, the tick that replays it runs no
    /// tick handler, so its state hash is the last tick's, as live recorded it.
    var shutdownTurnApplied: Bool = false
    /// The ordinal the pass applying now will take, between `beginPass` and `takePassOrdinal`
    /// (one synchronous segment); nil otherwise.
    var passInProgress: Int64?
    /// While true, tick and sync bodies do not start and tickless inputs are held.
    var debugFrozen: Bool = false
    /// Tick bodies and tickless input processing currently running.
    var debugInFlightWork: Int = 0
    var debugNextWaiterID: UInt64 = 0
    /// Generation of the freeze in effect, if any.
    var debugActiveGeneration: UInt64?
    /// Highest generation released by `debugResume(generation:)`; such a generation cannot freeze again.
    var debugReleasedGeneration: UInt64 = 0
    /// Tests: requests that passed `requestJoinSyncTurn`'s own guards (counted before
    /// `runSyncOnlyTurn`, whose guards may still skip the phase).
    var joinSyncRequestTurnsForTesting: Int = 0
    /// Sync-only turns run for waiting joins (tests).
    var joinSyncTurnsForTesting: Int = 0
    /// Requests by reason, made so far (tests and diagnostics).
    var requestedSyncTurnsForTesting: [SyncTurnReason: Int] = [:]
#if DEBUG
    /// Debug only: the most recent filled slots, so a second fill is caught even after the
    /// first was read and the slot removed. A bounded ring: memory stays fixed.
    var filledActionSlotsForAssert: Set<Int64> = []
    var filledActionSlotsOrderForAssert: [Int64] = []
    var filledActionSlotsNextForAssert: Int = 0
#endif

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
