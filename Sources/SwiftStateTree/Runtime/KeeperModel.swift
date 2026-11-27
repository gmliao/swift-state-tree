// Sources/SwiftStateTree/Runtime/KeeperModel.swift
//
// The keeper's plain state (#700 K1b-4): every field a turn reads or writes, and nothing that
// holds a reference, a closure or an existential other than `any P` with `P: PlainData` (the
// queued payloads). `@PlainData` checks that at compile time.

import Logging
import SwiftStateTurns

/// The keeper's machine: the land's state and the keeper's plain bookkeeping. The keeper holds
/// it as `model`; field names are the ones the keeper's stored properties had.
@PlainData
struct KeeperModel<State: StateNodeProtocol> {
    /// The land's generator: keeper state, advanced by the handlers that replay repeats from the
    /// record (#700 K1b-3, #765).
    var landRandom: DeterministicRng

    // The player table.
    /// The players in the land. Their services are beside the model, in the keeper's
    /// `playerServices`.
    var players: [PlayerID: KeeperPlayerEntry] = [:]
    /// Mints `KeeperPlayerEntry.generation`: every insert of a player entry gets a new one.
    var entryGenerations: EpochCounter = EpochCounter()
    /// Places reserved for duplicate logins that are between their cap check and their insert
    /// (#852): one reservation per pending attempt, not one per player. The kick of the old
    /// session awaits and the player's entry is gone meanwhile; a reservation keeps its place, so a
    /// newcomer can't take it. Overlapping logins of one player each hold their own, so the end of
    /// one never frees the place another still waits for. Only `joinReportingAdmission` reserves;
    /// teardown clears them all.
    var rejoinReservations: [PlayerID: Set<Epoch>] = [:]
    var rejoinReservationEpochs: EpochCounter = EpochCounter()
    /// The latest join attempt of each player to reach its decision (J2), by arrival
    /// (`joinArrivals`): the fencing token of #940. A kicking join that resumes after its kick's
    /// leave and finds a later arrival here is fenced out (J2c), so the last attempt to arrive
    /// keeps the player whichever kick returns first. Each attempt removes its own token on
    /// every exit, so the map holds only players with an attempt in flight.
    var latestJoinArrivals: [PlayerID: Epoch] = [:]
    var joinArrivals: EpochCounter = EpochCounter()
    /// The players whose leave is between its entry's removal and its OnLeave's append (#943),
    /// by the leaving entry's generation: L1 sets it when the OnLeave resolvers run, and the
    /// segment that ends that window ends it. A join of the player meanwhile waits for it
    /// (J2b's `.awaitLeave`), so no OnJoin of the player is appended before that OnLeave.
    var leavesInFlight: [PlayerID: Epoch] = [:]

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
    /// The held failures a core's record effect carries, by ID, with their input's sequence:
    /// their owner while the record is in flight (K2-2 plan, item 15, K22-Q5). Empty on the
    /// keeper's path, where `inputTurnResults` owns them.
    var inFlightRecordResults: [FailureID: Int64] = [:]
    /// The core's applied sequences whose record is in flight (`.awaitRecordTaken`), until
    /// `.recordTaken`: a wait registered for one of them meanwhile is answered with its result,
    /// not as an unknown sequence (Review on #948). Empty on the keeper's path.
    var inFlightRecordSequences: [Int64] = []
    /// Set when OnInitialize's resolvers timed out (#104): the land never initialized, every
    /// call that awaits the initialization throws it, and the drain skips the destroy handlers.
    var initializationFailure: FailureID?
    /// Mints failure IDs. Keeper-local: never reset, never restored from a record.
    var failureIDs: EpochCounter = EpochCounter()
    /// The input and output sequence numbers (#700 K1b-5 D15.3). A handler step lends it to the
    /// step's contexts (`KeeperSequenceLease`) and takes it back when the step ends.
    var sequence: KeeperSequenceCounter = KeeperSequenceCounter()
    /// The sync requests per tick. A handler step's requests are staged in the lease and ORed
    /// in when the step ends.
    var syncRequestsByTick: [Int64: KeeperSyncRequests] = [:]
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
    /// Where the initialization is: one phase per step of its flow, each set by the segment
    /// that enters it, on the keeper's path and the core's alike (K2-2 commit 1a). A result step
    /// on the core switches over every phase, so a result that finds the flow elsewhere is a
    /// named case, not a missed exit.
    var initializationPhase: InitializationPhase = .notStarted
    /// The initialization is over: done, failed, or ended by a drain.
    var didInitialize: Bool { initializationPhase.isOver }
    /// OnInitialize's body has applied (#946): the drain runs the destroy handlers only then (or
    /// on a land without OnInitialize). True from the record wait on, before `didInitialize`.
    /// #952's flag, now read from the phase (K2-2 plan §12).
    var initializationApplied: Bool { initializationPhase.applied }
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
    /// The core's barrier waits (K2-2 plan, commit 2): callers of `.freeze` and
    /// `.awaitInitialized` whose barrier was closed, answered by the step that opens it. Empty on
    /// the keeper's path, whose callers wait on continuations on the side.
    var coreBarrierWaits: KeeperCoreBarrierWaits = KeeperCoreBarrierWaits()
    /// Tests: requests that passed `requestJoinSyncTurn`'s own guards (counted before
    /// `runSyncOnlyTurn`, whose guards may still skip the phase).
    var joinSyncRequestTurnsForTesting: Int = 0
    /// Sync-only turns run for waiting joins (tests).
    var joinSyncTurnsForTesting: Int = 0
    /// Join sync turns scheduled after a committed phase (tests; #700 K1b-5a).
    var joinSyncTurnsScheduledForTesting: Int = 0
    /// Requests by reason, made so far (tests and diagnostics).
    var requestedSyncTurnsForTesting: [SyncTurnReason: Int] = [:]
#if DEBUG
    /// Debug only: the most recent filled slots, so a second fill is caught even after the
    /// first was read and the slot removed. A bounded ring: memory stays fixed.
    var filledActionSlotsForAssert: Set<Int64> = []
    var filledActionSlotsOrderForAssert: [Int64] = []
    var filledActionSlotsNextForAssert: Int = 0
#endif

    /// The land's state. A handler runs on `&model.state`, which is an access to the whole
    /// model: nothing may read another model field while it runs (one `inout` per step).
    /// Declared last: its size depends on the land, so a field after it would take its offset
    /// from the model's generic metadata at run time; before it, every field's offset is fixed.
    var state: State

    init(state: State, landRandom: DeterministicRng) {
        self.state = state
        self.landRandom = landRandom
    }
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
    /// The live keeper's recorder, when recording is on (#700 K1b-5 rev 2.3 D12). Fixed at init.
    let reevaluationRecorder: ReevaluationRecorder?
    /// The re-entry sentinel (#865; #700 K1b-5 rev 2.3 D13). A reference, the one the behavior
    /// contract's advice (values and functions) makes an exception for: it is used on the
    /// keeper's executor only, written by the refusing entries and `withTurn`'s depth count, and
    /// read by a body only to end the land through its own model.
    let reentrySentinel: KeeperReentrySentinel
    /// A core-driven keeper's turn side (#700 K2-1, `KeeperSideStore`), the second stated
    /// exception to the advice above. Nil on the keeper, which borrows its own stored side.
    var sideStore: KeeperSideStore? = nil
}

/// What the behavior's fixed fields decide (#700 K1b-5 move, step 1): the reads a turn body made
/// through the actor, now on the behavior it is lent.
extension KeeperBehavior {
    /// A land without a tick handler: every turn records under one tick id.
    var isTickless: Bool { definition.lifetimeHandlers.tickHandler == nil }
    /// Live keepers' inputs, ticks and initialization run as turns (#546 L2d).
    var routesThroughTurn: Bool { config.mode == .live }
    /// Something reads input records: a recorder, or a replay.
    var recordsInputs: Bool { reevaluationRecorder != nil || config.mode != .live }
    /// Whether passes are numbered: a tickless land that records (live, with a recorder) or
    /// replays.
    var countsPasses: Bool { isTickless && (reevaluationRecorder != nil || config.mode == .reevaluation) }
    /// Whether the land syncs on its own (a tick loop or a sync loop); mirrors the loop setup in
    /// `performInitialization`.
    var hasPeriodicSync: Bool {
        guard config.autoStartLoops else { return false }
        let handlers = definition.lifetimeHandlers
        let tickLoop = handlers.tickInterval != nil && handlers.tickHandler != nil
        let syncLoop = handlers.syncInterval != nil || handlers.tickInterval != nil
        return tickLoop || syncLoop
    }
    /// The coincident-sync window: min(5 ms, tick / 4, sync / 4).
    var coincidentSyncWindow: Duration {
        var window = Duration.milliseconds(5)
        if let tick = definition.lifetimeHandlers.tickInterval { window = min(window, tick / 4) }
        if let sync = definition.lifetimeHandlers.syncInterval { window = min(window, sync / 4) }
        return window
    }
}

/// The re-entry sentinel's state (#865): the body depth the guarded entries read, the refusals
/// they counted and the gate the first refusal closed. Used on the keeper's executor only.
final class KeeperReentrySentinel: @unchecked Sendable {
    /// Turn bodies running now (0 or 1; `withTurn` doesn't nest). The adapter-facing entries
    /// read it to refuse a synchronous re-entry during a body (`noteReentry`). Kept outside
    /// the turn side, which the body has borrowed.
    var bodyDepth = 0
    /// Re-entries refused so far (`noteReentry`). A call out of the keeper compares it before
    /// and after (`callOut`).
    var reentryViolations = 0
    /// The failure the first refused re-entry reported.
    var reentryFailure: LandFailure?
    /// Set while the sentinel closes the output gate, so a gate whose close calls back into the
    /// keeper can't recurse into it.
    var closingGateForReentry = false
    /// Whether the sentinel closed a gate (none is attached on a land without a transport).
    var reentryGateClosed = false
    /// The gate the sentinel closed, when it is a class instance (`gateObject`), held weakly, so
    /// `failLand` skips only that gate's second close: a transport attached after the sentinel
    /// closed the bound requester still gets its close, and a freed gate's address reused by a
    /// new transport can't match it.
    weak var reentryClosedGate: AnyObject?
    /// Refused re-entries the backstop applied (tests).
    var lateReentriesApplied = 0
    /// How many refused re-entries a `callOut` applied in its own call (tests: a bare port call's
    /// refusal is applied by a later mailbox check or the backstop instead, and isn't counted).
    var reentriesAppliedInCall = 0

    init() {}
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

/// The re-evaluation fields (#700 K1b-4, D2): set on a keeper that already exists
/// (`ReevaluationEngine`, `ReevaluationRunnerImpl`); a live keeper keeps the defaults. Not plain:
/// it holds the source, the sink and an observer closure. #612 removes the group with the replay
/// land's owner.
struct ReplayFields {
    /// Source for reading recorded inputs during re-evaluation (only in .reevaluation mode).
    var reevaluationSource: (any ReevaluationSource)?
    /// Optional sink for emitting recorded outputs during re-evaluation.
    var reevaluationSink: (any ReevaluationSink)?
    /// The encoding of a replayed entry that names none: the record header's (#700 K1a).
    var replayHeaderPayloadEncoding: RecordPayloadEncoding = .json
    /// Re-evaluation: OnInitialize was replayed before tick 0 from the record's initialize
    /// record, so tick 0 skips its `initialize` lifecycle event.
    var replayedInitializeBeforeTickZero: Bool = false
    /// Re-evaluation: OnInitialize's `validate` threw on the recorded inputs (#593), set once,
    /// naming the handler and the error. The record holds an initialize entry only when the live
    /// `validate` passed, so the replay contradicts it: `ReevaluationEngine.verifyInitialize`
    /// reports `.failed`. Nothing was written, as live.
    var replayedInitializeRefusal: String?
    /// Re-evaluation: where the recorded failure ended its turn among its inputs
    /// (`LandFailurePosition.endsInputs`): the tick (a tick land's tick handler is skipped and
    /// its events dropped) or, tickless, the pass whose events are dropped. Replay doesn't end
    /// the land (`failLand` returns early), so it ends that work by this instead.
    var replayFailureEnd: ReplayFailureEnd?
    /// Re-evaluation: the record is 3.4 or later, so every tickless pass carries its ordinal.
    var replayRecordsPassOrdinals: Bool = false
    /// Re-evaluation: the record is 3.5 or later, so its passes and tick frames list the inputs
    /// refused live (`rejected`, #586), and a missing list means none was.
    var replayRecordsRejected: Bool = false
    /// Re-evaluation: the inputs refused since the last `takeReplayRejected()`, in apply order.
    var replayRejected: [Int64] = []
    /// Re-evaluation: why each replayed tick's record can't be reproduced: its passes don't match
    /// its inputs (`replayRecordedPasses`), or it holds a server input the land doesn't declare.
    var recordedPassMismatches: [Int64: String] = [:]
}

// MARK: - The keeper's nested types the model holds (were private to `LandKeeper.swift`)

/// A player's entry in the land (was `InternalPlayerSession`), without its services: those are
/// references, so they live in the keeper's `playerServices`, keyed by this entry's generation.
@PlainData
struct KeeperPlayerEntry: Sendable {
    var clientID: ClientID?
    var lastSessionID: SessionID?
    /// This entry's generation, new on every insert (`KeeperModel.entryGenerations`). Client and
    /// session IDs can repeat across joins of the same player, so work that awaits after
    /// reading the entry compares this instead: a join whose resolvers end after the land started
    /// draining removes only its own entry, and an action is delivered only to the entry it was
    /// sent to (`LandKeeper.deliverResolvedAction`).
    var generation: Epoch = Epoch(rawValue: 0)
    /// This entry's join appends an OnJoin input once its OnJoin resolvers end: set in the
    /// insert's segment, cleared in the append's (#860). A leave that removes the entry meanwhile
    /// (the session's own, or a newer login's kick) appends no OnLeave, and the join's append,
    /// finding its entry gone, drops the OnJoin and throws `JoinError.superseded`: the pair is
    /// dropped together, so a player's applied OnJoin and OnLeave inputs stay in order.
    var onJoinPending: Bool = false
    // PlayerSession info (from join request)
    var deviceID: String?
    var isGuest: Bool
    var metadata: [String: String]

    init(deviceID: String? = nil, isGuest: Bool = false, metadata: [String: String] = [:]) {
        clientID = nil
        lastSessionID = nil
        self.deviceID = deviceID
        self.isGuest = isGuest
        self.metadata = metadata
    }
}

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

/// The keeper's sequence counter: one number per input and per emitted event, in order.
@PlainData
struct KeeperSequenceCounter: Sendable, Equatable {
    var next: Int64 = 0
    /// Re-evaluation only: a take past `Int64.max` stops the replay instead of the process (#741).
    /// A live counter starts at 0 and traps first, so the live path keeps the plain increment.
    var checksOverflow: Bool = false
    /// Set by the first take that found no number left; read at the run's step boundaries.
    var exhausted: Bool = false

    mutating func take() -> Int64 {
        let s = next
        guard checksOverflow else {
            next += 1
            return s
        }
        let (following, overflow) = s.addingReportingOverflow(1)
        if overflow {
            // The counter stays at Int64.max and the number repeats: the run ends at its next
            // step boundary (`replaySequenceExhausted()`), and what it computed meanwhile is dropped.
            exhausted = true
        } else {
            next = following
        }
        return s
    }
}

/// A turn machine is `Sendable` (`TurnMachine`); its conformance has to be declared beside the
/// model (#700 K2-1). Every stored field is plain data.
extension KeeperModel: Sendable {}

/// The initialization's flow, one case per await between its segments (K2-2 commit 1a). The
/// legacy re-evaluation path (#612) is a phase of its own, which a core never enters.
@PlainData
enum InitializationPhase: Equatable, Sendable {
    /// `initializeBegin` hasn't run.
    case notStarted
    /// A re-evaluation keeper's replay of the initialization (the keeper's own path, #612).
    case replaying
    /// OnInitialize's resolvers run as an await (an effect on the core); its sequence number
    /// is taken.
    case resolving(sequence: Int64)
    /// OnInitialize applied; its record is with the recorder. No sequence: only the flow's own
    /// record effect answers it, and no step would read one (Review on #966).
    case recording
    /// OnInitialize applied (or the land has none); the finish runs in a step of its own.
    case finishing
    /// The owner configures the loops, then the initialization is done.
    case startingLoops
    /// Done: the land is open.
    case done
    /// Failed: the failure is held (`initializationFailure`) and the teardown staged.
    case failed
    /// A drain began before OnInitialize applied (during its resolvers): OnInitialize is
    /// dropped and the failure held, with no teardown of its own (#952).
    case abandonedByDrain

    var isOver: Bool {
        switch self {
        case .done, .failed, .abandonedByDrain: true
        case .notStarted, .replaying, .resolving, .recording, .finishing, .startingLoops: false
        }
    }

    /// OnInitialize's body has applied: every phase after `.resolving` on the live path. A land
    /// without OnInitialize goes from `.notStarted` to `.finishing`, and its drain reads the
    /// definition instead (`drainAfterTicks`).
    var applied: Bool {
        switch self {
        case .recording, .finishing, .startingLoops, .done: true
        case .notStarted, .replaying, .resolving, .failed, .abandonedByDrain: false
        }
    }
}
