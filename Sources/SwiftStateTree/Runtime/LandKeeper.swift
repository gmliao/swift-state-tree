import Foundation
import Logging

// MARK: - Helper for Replay Mode

// Note: AnyCodableResolverOutput is now defined in LandContext.swift for access by dynamic member lookup

/// The runtime executor for a Land instance.
///
/// `LandKeeper` is an actor that manages the authoritative state and executes the handlers
/// defined in a `LandDefinition`. It handles:
/// - Player join/leave lifecycle
/// - Action and event processing
/// - Periodic ticks
/// - Automatic shutdown when empty
/// - State synchronization using snapshot model
///
/// All state mutations are serialized through the actor, ensuring thread-safety.
/// Sync operations use snapshot model - they take a snapshot at the start and work with it,
/// allowing mutations to proceed concurrently without blocking.
///
/// **Sync Model**: Snapshot-based, non-blocking
/// - Sync takes a snapshot of state at the start
/// - Mutations can proceed concurrently (not blocked by sync)
/// - Each sync gets a consistent snapshot (actor serialization ensures this)
/// - Sync deduplication prevents redundant concurrent sync operations
///
///     /// TODO: Performance considerations:
///     /// - When Resolver mechanism is implemented and Action Handlers become synchronous,
///     ///   we may be able to directly modify state without copying
///     /// - Consider sync queue or debouncing for high-frequency sync scenarios
public enum LandMode: Sendable {
    case live
    case reevaluation
}

/// Output mode for reevaluation mode: when to forward emitted events.
public enum ReevaluationOutputMode: Sendable {
    /// Only forward to reevaluation sink (default, backward compatible).
    case sinkOnly
    /// Forward to both transport and sink (for same-land replay streaming).
    case transportAndSink
}

/// Where a `LandKeeper` awaits its test hold hook (`installHolds`).
enum LandKeeperHoldPoint: Hashable, Sendable {
    /// `forceShutdown`, right after its shutdown turn applied and before the destroy (#382).
    case shutdownTurnApplied
    /// A tickless legacy land's shutdown pass, before it applies the ready inputs (#382).
    case legacyShutdownPass
    /// The start of the destruction, after `isDraining` is set and before any destroy handler.
    case drainStart
    /// Both `join` variants, after their checks and before the player insert.
    case join
    /// The start of `leave(playerID:clientID:sessionID:)`.
    case leave
    /// The start of each input drain, before its first turn.
    case inputDrain
    /// A tickless server input's task, before it waits for (or runs) the turn applying it.
    case serverInputKick
    /// After an input turn's record is enqueued (in the turn's synchronous segment), or after a
    /// legacy pass's record and delivery are enqueued: the inputs are applied and their callers
    /// wait only for the record (and, legacy, its delivery, which doesn't wait for this hold).
    case turnRecord
    /// The start of a legacy tickless pass's delivery job (`legacyDeliveries`), before it waits
    /// for the pass's record.
    case legacyDelivery
    /// The start of an action job's completion (`completeAction`), before its segment.
    case actionComplete
    /// The trigger pass a tickless job's completion starts (in-turn sync off), before it
    /// applies anything: the job is delivered and waits in the queue.
    case ticklessJobPass
    /// The end of `submitAction`, before it returns or throws to its caller: its intake (and
    /// a job's registration) is done.
    case actionSubmitted
}

/// What `LandKeeper.submitAction` did with an action.
package enum ActionSubmission: Sendable {
    /// Handled through: its response (an ACK on a tick land, the handler's on a tickless one).
    case completed(AnyCodable)
    /// Its resolvers run in a job: `LandKeeper.awaitActionResult(sequence:)` returns its outcome.
    case pending(sequence: Int64)
}

/// `LandKeeper.awaitActionResult(sequence:)` was called for a sequence with no unread slot: no
/// job was submitted under it, or its outcome was already read.
package struct ActionResultUnavailable: Error, Equatable {
    package let sequence: Int64
}

/// Set by an action job's caller when it is cancelled, from its cancellation handler, which
/// can't wait for the keeper; read by the job's completion segment.
private final class ActionJobCallerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

public actor LandKeeper<State: StateNodeProtocol>: LandKeeperProtocol {
    /// Unified pending item for every input kind (`package`: nothing public takes or returns it).
    package enum PendingItem: Sendable {
        case action(PendingActionItem)
        case clientEvent(PendingClientEventItem)
        case lifecycle(PendingLifecycleItem)
        case serverInput(PendingServerInputItem)
        /// `forceShutdown`'s turn (#382): recorded as the lifecycle event kind `"shutdown"`.
        case shutdown(PendingShutdownItem)
    }

    /// A server input (#387), taken at submit: the system identity applies it.
    package struct PendingServerInputItem: Sendable {
        package let sequence: Int64
        package let typeIdentifier: String
        package let payload: AnyCodable
        package let resolvedAtTick: Int64
    }

    /// The forced shutdown's input (#382). Its turn clears the players without OnLeave, drops
    /// every input still queued and starts the drain, in one synchronous segment
    /// (`applyInputs`).
    package struct PendingShutdownItem: Sendable {
        package let sequence: Int64
        package let resolvedAtTick: Int64
    }

    /// The recorded lifecycle event kind of the shutdown turn (`PendingItem.shutdown`).
    static var shutdownLifecycleKind: String { "shutdown" }

    public enum LifecycleKind: String, Codable, Sendable {
        case initialize
        case join
        case leave
    }

    public struct PendingLifecycleItem: Sendable {
        public let sequence: Int64
        public let kind: LifecycleKind
        public let playerID: PlayerID?
        public let clientID: ClientID?
        public let sessionID: SessionID?
        public let deviceID: String?
        public let isGuest: Bool?
        public let metadata: [String: String]
        public let resolverOutputs: [String: any ResolverOutput]
        public let resolvedAtTick: Int64
        /// For a join's OnJoin: the generation of the player entry that join inserted (`nil`
        /// otherwise, and in replay). A failed OnJoin removes the entry only while it is still
        /// that generation (`discardIfFailedJoin`).
        public let entryGeneration: Epoch?

        public init(
            sequence: Int64,
            kind: LifecycleKind,
            playerID: PlayerID?,
            clientID: ClientID?,
            sessionID: SessionID?,
            deviceID: String?,
            isGuest: Bool?,
            metadata: [String: String],
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64,
            entryGeneration: Epoch? = nil
        ) {
            self.sequence = sequence
            self.kind = kind
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.deviceID = deviceID
            self.isGuest = isGuest
            self.metadata = metadata
            self.resolverOutputs = resolverOutputs
            self.resolvedAtTick = resolvedAtTick
            self.entryGeneration = entryGeneration
        }
    }

    public struct PendingActionItem: Sendable {
        public let sequence: Int64
        public let action: AnyCodable
        public let actionType: any ActionPayload.Type
        public let playerID: PlayerID
        public let clientID: ClientID
        public let sessionID: SessionID
        public let resolverOutputs: [String: any ResolverOutput]
        public let resolvedAtTick: Int64

        public init(
            sequence: Int64,
            action: AnyCodable,
            actionType: any ActionPayload.Type,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.action = action
            self.actionType = actionType
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolverOutputs = resolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }
    }

    public struct PendingClientEventItem: Sendable {
        public let sequence: Int64
        public let event: AnyClientEvent
        public let playerID: PlayerID
        public let clientID: ClientID
        public let sessionID: SessionID
        public let resolvedAtTick: Int64

        public init(
            sequence: Int64,
            event: AnyClientEvent,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.event = event
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolvedAtTick = resolvedAtTick
        }
    }

    // Legacy PendingAction kept for backward compatibility during migration
    public struct PendingAction<ID: Hashable & Sendable>: Sendable {
        public let id: ID
        public let action: AnyCodable
        public let actionType: any ActionPayload.Type
        public let playerID: PlayerID
        public let clientID: ClientID
        public let sessionID: SessionID
        public let resolverOutputs: [String: any ResolverOutput]
        public let resolvedAtTick: Int64

        public init(
            id: ID,
            action: AnyCodable,
            actionType: any ActionPayload.Type,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.id = id
            self.action = action
            self.actionType = actionType
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolverOutputs = resolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }
    }

    public let definition: LandDefinition<State>

    private var state: State
    private var players: [PlayerID: InternalPlayerSession] = [:]
    /// Mints `InternalPlayerSession.generation`: every insert of a player entry gets a new one.
    private var entryGenerations = EpochCounter()
    private var services: LandServices

    private var transport: LandKeeperTransport?
    private let logger: Logger
    private let autoStartLoops: Bool
    /// Delay each loop's first iteration by `LandLoopPhase.offset` (see `loopPhaseOffset`).
    private let enableLoopPhaseOffset: Bool
    private let enableLiveStateHashRecording: Bool
    private var stateHashUnavailableTotal = 0
    private let reevaluationOutputMode: ReevaluationOutputMode

    private var pendingItems: [PendingItem] = []
    /// Server inputs submitted and not yet applied (`SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND`).
    private var serverInputsInFlight = 0
    private var serverInputMaxInFlight = ServerInputLimits.maxInFlightPerLand()
    /// Server inputs refused because the in-flight cap was reached.
    public private(set) var serverInputCapRejections = 0
    private var mode: LandMode

    private struct EmittedEvent: Sendable {
        let sequence: Int64
        let tickId: Int64
        let event: AnyServerEvent
        let target: EventTarget
    }

    private struct SyncRequests: Sendable {
        var syncNow: Bool = false
        var syncBroadcastOnly: Bool = false
    }

    private final class OutputCollector: @unchecked Sendable {
        var nextSequence: Int64 = 0
        var emittedEvents: [EmittedEvent] = []
        var syncRequestsByTick: [Int64: SyncRequests] = [:]

        func takeNextSequence() -> Int64 {
            let s = nextSequence
            nextSequence += 1
            return s
        }

        func enqueueEmittedEvent(_ anyEvent: AnyServerEvent, to target: EventTarget, tickId: Int64) {
            let seq = takeNextSequence()
            emittedEvents.append(EmittedEvent(sequence: seq, tickId: tickId, event: anyEvent, target: target))
        }

        func requestSyncNow(tickId: Int64) {
            var req = syncRequestsByTick[tickId] ?? SyncRequests()
            req.syncNow = true
            syncRequestsByTick[tickId] = req
        }

        func requestSyncBroadcastOnly(tickId: Int64) {
            var req = syncRequestsByTick[tickId] ?? SyncRequests()
            req.syncBroadcastOnly = true
            syncRequestsByTick[tickId] = req
        }
    }

    private let outputCollector = OutputCollector()

    /// Recorder for deterministic re-evaluation (only in .live mode).
    private var reevaluationRecorder: ReevaluationRecorder?
    /// Position of the next sync-stream entry (output or marker). Advanced only while the land
    /// records its sync stream (a recorder and in-turn sync), in the same synchronous segment as
    /// the entry it numbers; replay orders the stream by it.
    private var syncStreamCounter: UInt64 = 0
    /// The kind of turn whose sync phase is running, for the sync outputs it records.
    private var inTurnSyncTurnKind: ReevaluationRecordedSyncOutput.TurnKind = .tick
    /// The last recorded output's `observedTickId` and how many outputs were recorded after it
    /// (`ReevaluationRecordedSyncOutput.index`).
    private var syncOutputIndexCursor: (observedTickId: Int64?, count: Int) = (nil, 0)

    /// Source for reading recorded inputs during re-evaluation (only in .reevaluation mode).
    private var reevaluationSource: (any ReevaluationSource)?

    /// Optional sink for emitting recorded outputs during re-evaluation.
    private var reevaluationSink: (any ReevaluationSink)?

    /// Actual land instance ID (e.g., "counter:550e8400-...")
    /// This is different from definition.id which is just the land type (e.g., "counter")
    private var actualLandID: String?

    /// Set the transport interface (called after TransportAdapter is created). A keeper whose
    /// destruction has finished keeps its released placeholder instead: a transport attached
    /// after it (a land whose initialization failed before it was wired) would never be
    /// released (#346).
    public func setTransport(_ transport: LandKeeperTransport?) {
        let attached = destructionFinished ? releasedTransport : transport
        self.transport = attached
        transportRecordsFolds = attached?.recordsInTurnSyncFolds ?? false
    }

    /// The destruction made its last call to the transport (`notifyTransportDestroyedAndRelease`).
    private var destructionFinished = false

    /// The transport of a destroyed keeper: it holds nothing (so the adapter is released) and
    /// counts the calls late keeper work still makes, which a released adapter would otherwise
    /// never see. Set when the destruction finishes.
    private var releasedTransport: ReleasedLandTransport?

    /// Transport calls made after the destruction finished, dropped (events, sync requests).
    /// The adapter counted such late frames as dropped (`droppedAfterFinish`) while it was
    /// attached; once it is released the keeper counts them here (#346).
    package var transportCallsAfterDestruction: Int { releasedTransport?.dropped ?? 0 }

    /// `transport?.recordsInTurnSyncFolds`, read when the transport is attached.
    private var transportRecordsFolds = false

    /// Tests: the transport attached now (after the destruction, the released placeholder,
    /// `ReleasedLandTransport`, #346).
    var transportForTesting: LandKeeperTransport? { transport }

    /// Set the actual land instance ID (called after LandKeeper is created)
    /// This allows LandContext to use the actual instance ID instead of just the land type
    /// Also updates the RNG service seed if it was created with a default seed
    public func setLandID(_ landID: String) {
        actualLandID = landID

        // Update RNG service seed if it was created with definition.id seed
        // This ensures deterministic behavior based on actual land instance ID
        if let rngService = services.get(DeterministicRngService.self),
           rngService.seed == DeterministicSeed.fromLandID(definition.id)
        {
            // Replace with new RNG service using actual landID seed
            let newSeed = DeterministicSeed.fromLandID(landID)
            let newRngService = DeterministicRngService(seed: newSeed)
            var updatedServices = services
            updatedServices.register(newRngService, as: DeterministicRngService.self)
            services = updatedServices
        }
    }

    /// Get the RNG seed for recording purposes.
    /// Returns the seed from the DeterministicRngService if it exists, nil otherwise.
    public func getRngSeed() -> UInt64? {
        return services.get(DeterministicRngService.self)?.seed
    }

    private var tickTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var destroyTask: Task<Void, Never>?
    /// The destruction in progress (single-flight): `shutdownIfIdle` runs it once.
    private var drainTask: Task<Void, Never>?
    private let drainFlag = DrainFlag()

    /// The land is being destroyed, or was: it became empty and its destruction started.
    ///
    /// Set synchronously right after the emptiness check, before the first await of the
    /// destruction, and never cleared. A draining keeper rejects joins
    /// (`JoinError.landShuttingDown`), and `LandManager` treats it as absent. Readable without
    /// awaiting the keeper, so a caller can check it in the same synchronous segment as its act.
    public nonisolated var isDraining: Bool { drainFlag.isSet }

    /// Why this land's destruction started, once it has (`nil` before). Set in the same
    /// synchronous segment as `isDraining`, by the first caller only, and never changed.
    public nonisolated var destructionCause: LandDestructionCause? { drainFlag.cause }

    /// Waits until this keeper's destruction has finished, handlers and the transport's
    /// `onLandDestroyed` included. Returns at once when no destruction started.
    ///
    /// `LandManager` awaits it before creating a new instance for the same LandID, so the old
    /// instance's finalize never overlaps the new one's initialize.
    public func waitUntilDrained() async {
        if let drainTask {
            await drainTask.value
        }
    }

    /// Forced-interleaving hold points (tests only; a no-op unless installed).
    private var holds = HoldPoints<LandKeeperHoldPoint>()

    /// Installs (or, with `nil`, removes) the hold hook for every `LandKeeperHoldPoint` (tests).
    func installHolds(_ hook: (@Sendable (LandKeeperHoldPoint) async -> Void)?) {
        holds.install(hook)
    }
    private var initializationTask: Task<Void, Never>?
    /// Set when OnInitialize's resolvers timed out (#104): the land never initialized, every
    /// call that awaits the initialization throws it, and the drain skips the destroy handlers.
    private var initializationFailure: LandInitializationError?
    private var didInitialize = false
    /// Re-evaluation: OnInitialize was replayed before tick 0 from the record's initialize
    /// record, so tick 0 skips its `initialize` lifecycle event.
    private var replayedInitializeBeforeTickZero = false

    /// Next tick ID (0-based, increments with each tick) for deterministic replay.
    /// This represents the ID that will be assigned to the next tick execution.
    /// Using Int64 for long-running servers and replay compatibility.
    private var nextTickId: Int64 = 0

    /// Last committed tick ID (the most recent tick that has completed execution).
    /// This represents the world state's current committed tick.
    /// Action/Event handlers should use this to bind to the committed world state.
    /// Initialized to -1 to indicate no ticks have been committed yet.
    private var lastCommittedTickId: Int64 = -1

    private func flushOutputs(forTick tickId: Int64) async {
        let toFlush = outputCollector.emittedEvents
            .filter { $0.tickId == tickId }
            .sorted { $0.sequence < $1.sequence }
        if !toFlush.isEmpty {
            // Remove flushed events first to keep deterministic behavior even if downstream awaits.
            outputCollector.emittedEvents.removeAll { $0.tickId == tickId }
        }

        switch mode {
        case .live:
            for item in toFlush {
                await transport?.sendEventToTransport(item.event, to: item.target)
            }
            // Record server events for verification when reevaluation recording is enabled
            if let recorder = reevaluationRecorder, !toFlush.isEmpty {
                let records = toFlush.map { item in
                    ReevaluationRecordedServerEvent(
                        kind: "serverEvent",
                        sequence: item.sequence,
                        tickId: item.tickId,
                        typeIdentifier: item.event.type,
                        payload: item.event.payload,
                        target: ReevaluationEventTargetRecord.from(item.target)
                    )
                }
                await recorder.recordServerEvents(tickId: tickId, events: records)
            }
        case .reevaluation:
            if reevaluationOutputMode == .transportAndSink {
                for item in toFlush {
                    await transport?.sendEventToTransport(item.event, to: item.target)
                }
            }
            if let sink = reevaluationSink, !toFlush.isEmpty {
                let records = toFlush.map { item in
                    ReevaluationRecordedServerEvent(
                        kind: "serverEvent",
                        sequence: item.sequence,
                        tickId: item.tickId,
                        typeIdentifier: item.event.type,
                        payload: item.event.payload,
                        target: ReevaluationEventTargetRecord.from(item.target)
                    )
                }
                await sink.onEmittedServerEvents(tickId: tickId, events: records)
            }
        }

        await runSyncRequests(outputCollector.syncRequestsByTick.removeValue(forKey: tickId))
    }

    /// Runs the sync requests a tick's handlers made (`ctx.requestSyncNow()` and the like),
    /// taken from `outputCollector.syncRequestsByTick` by the caller.
    private func runSyncRequests(_ requests: SyncRequests?) async {
        guard let req = requests else { return }
        if usesInTurnSync, req.syncNow || req.syncBroadcastOnly {
            // In-turn paths take their own requests; one left here runs as a sync-only turn
            // (a broadcast-only request runs the full phase, as in a turn).
            runSyncOnlyTurnIfInTurn()
        } else if mode == .live {
            if req.syncNow {
                await transport?.syncNowFromTransport()
            } else if req.syncBroadcastOnly {
                await transport?.syncBroadcastOnlyFromTransport()
            }
        }
    }

    /// Flag to prevent duplicate sync operations (for deduplication only).
    ///
    /// **Note**: This flag is used for deduplication, NOT for blocking mutations.
    /// Sync operations use snapshot model - they take a snapshot of state at the start,
    /// which naturally provides consistency without blocking mutations.
    ///
    /// When sync is in progress, concurrent sync requests are skipped to avoid redundant work.
    /// Mutations (actions/events) are NOT blocked and can proceed concurrently with sync.
    ///
    /// TODO: Future optimizations to consider:
    /// - Sync queue: Queue sync requests and batch them to reduce overhead
    /// - Debouncing: Debounce rapid sync requests to reduce frequency
    /// - Metrics: Track sync frequency and performance
    private var isSyncing = false

    // MARK: In-turn sync state (see `InTurnSync`)

    /// Whether this keeper's turns run the sync phase inside the turn: live mode, and the
    /// transport runs it for this keeper (`LandKeeperTransport.runsSyncPhaseInTurn(of:)`, which
    /// follows the adapter's switch). Never true for a transport attached to another keeper, so
    /// no turn reaches an `assumeIsolated` that would trap. The switch is fixed once the
    /// transport is set.
    private var usesInTurnSync: Bool {
        mode == .live && (transport?.runsSyncPhaseInTurn(of: self) ?? false)
    }

    /// The next tick turn includes the sync phase: set when the sync loop fires within
    /// `coincidentSyncWindow` of the next tick (the coincident-sync rule).
    private var inTurnSyncDue = false

    /// Syncs the sync loop folded into a coincident tick turn (diagnostics).
    private(set) var foldedSyncs = 0

    /// Of `foldedSyncs`, those whose tick deadline had already passed at the fold. Mostly a race
    /// between the phase-locked tick and sync loops, not tick lateness (#232; diagnostics).
    private(set) var overdueFoldedSyncs = 0

    /// Folded syncs whose tick turn started later than `coincidentSyncWindow` after the deadline
    /// the sync folded on (#232): counted when that turn starts (diagnostics).
    private(set) var lateFoldedSyncs = 0

    /// The fold waiting for its tick turn: the tick deadline it folded on and whether that
    /// deadline had passed. Set with `inTurnSyncDue` by a fold, taken when a tick turn starts.
    private var pendingFold: (deadline: ContinuousClock.Instant, overdueAtFold: Bool)?

    /// Turns whose sync phase was deferred by writer back-pressure (diagnostics).
    private(set) var inTurnDeferredTurns = 0

    /// Sync-only turns run to repair a failed in-turn plan (diagnostics).
    private(set) var inTurnRepairTurns = 0

    /// A land without periodic sync: a sync-only turn waits for the writer to drain (at most one).
    private var inTurnDrainRetryPending = false

    /// A land without periodic sync: a repair sync-only turn is scheduled (at most one).
    private var inTurnRepairPending = false

    /// A turn wanted a sync phase while a legacy cycle (`beginSync` ... `endSync`: the debug
    /// settle, a joiner's path) held the sync flag: `endSync` then runs a sync-only turn, so the
    /// request is not lost.
    private var syncOnlyTurnAfterLegacyCycle = false

    /// The tick loop's next deadline: set by the loop after each tick, cleared when the tick starts.
    private var nextTickDeadline: ContinuousClock.Instant?

    /// The coincident-sync window: min(5 ms, tick / 4, sync / 4). A sync loop firing this close
    /// to the next tick folds into that tick turn instead of overtaking it.
    private var coincidentSyncWindow: Duration {
        var window = Duration.milliseconds(5)
        if let tick = definition.lifetimeHandlers.tickInterval { window = min(window, tick / 4) }
        if let sync = definition.lifetimeHandlers.syncInterval { window = min(window, sync / 4) }
        return window
    }

    /// Tickless lands: an input drain is scheduled or running (one at a time).
    private var inputDrainScheduled = false

    /// Tickless lands: callers waiting for their input's turn, by input sequence. Actions get
    /// their own response; other inputs get an empty one (or the handler's error).
    private var inputTurnWaiters: [Int64: CheckedContinuation<AnyCodable, any Error>] = [:]

    /// Maximum inputs applied in one tickless input turn, so continuous input cannot starve the
    /// sync loop (other jobs run between turns).
    static var inputTurnBatchLimit: Int { 64 }

    /// Delay before a repair sync-only turn after a failed in-turn plan.
    static var inTurnRepairDelay: Duration { .milliseconds(100) }

    /// The last recorder submission. Each submission awaits the one before it, so turn records
    /// reach the recorder in turn order.
    /// Orders recorder submissions and lets the shutdown saver wait for them.
    private let recorderSubmissions = ReevaluationSubmissionTracker()
    /// Legacy tickless passes' delivery jobs, one per pass in apply order (`finishTicklessLegacyPass`).
    private let legacyDeliveries = ReevaluationSubmissionTracker()
    /// Recorder submissions enqueued so far: a turn compares it with its start to know whether
    /// it recorded anything (a tickless sync-only turn then ends its turn record, #327).
    private var recorderSubmissionCount = 0

    /// A land without a tick handler: every turn records under one tick id, so the keeper
    /// closes each turn's record itself (`ReevaluationRecorder.endTurn()`, #327).
    private var isTickless: Bool { definition.lifetimeHandlers.tickHandler == nil }

    /// Tests only: called with turn markers ("turn-begin", "sync-committed", "turn-end"), the
    /// input drain's end ("input-drain-end"), intake points ("action-queued", "input-held-frozen"),
    /// the forced shutdown's steps ("force-shutdown-joined", "shutdown-stop-gate",
    /// "shutdown-queued") and labels passed to `recordInTurnProbeForTesting`.
    private var inTurnProbeForTesting: (@Sendable (String) -> Void)?

    /// Tests only (the probe's negative control): one `await Task.yield()` inside the tick turn,
    /// after "turn-begin" and before the synchronous core.
    private var inTurnYieldForTesting = false

    /// Installs `inTurnProbeForTesting` (tests only).
    func setInTurnProbeForTesting(_ probe: (@Sendable (String) -> Void)?) {
        inTurnProbeForTesting = probe
    }

    /// Tests only: a job on this keeper's executor that records `label`.
    func recordInTurnProbeForTesting(_ label: String) {
        inTurnProbeForTesting?(label)
    }


    /// Tests only: the ticks with sync requests still in the output collector.
    func syncRequestTicksForTesting() -> [Int64] {
        outputCollector.syncRequestsByTick.keys.sorted()
    }

    /// Inputs `applyPendingItem` skipped because the destroy handlers had started (tests read it;
    /// every append path checks `isDraining`, so it stays 0).
    private(set) var inputsSkippedAfterDestroy = 0

    /// Tickless intake callers held by a freeze (tests only).
    var debugHeldInputCount: Int { debugHeldInputs.count }

    /// The empty-room destroy timer, if one is armed (tests only): awaiting its value waits for
    /// the timer and the destruction it starts, or returns at once once it was cancelled.
    func destroyTimerForTesting() -> Task<Void, Never>? {
        destroyTask
    }

    /// Whether the tick loop has been started (tests only).
    func hasTickLoopForTesting() -> Bool {
        tickTask != nil
    }

    /// Installs `inTurnYieldForTesting` (tests only).
    func setInTurnYieldForTesting(_ enabled: Bool) {
        inTurnYieldForTesting = enabled
    }

    /// Tests only: runs `body` as a job on this keeper's executor.
    func runIsolatedForTesting(_ body: @Sendable () -> Void) {
        body()
    }

    /// Tests only: sets the tick loop's next deadline (the coincident-sync rule's input).
    /// Whether a sync is folded into the next tick turn (tests only).
    var inTurnSyncDueForTesting: Bool { inTurnSyncDue }

    func setNextTickDeadlineForTesting(_ deadline: ContinuousClock.Instant?) {
        nextTickDeadline = deadline
    }

    /// Tests only: the cadence diagnostics in one call, without copying the state (a sampler's
    /// probe on the keeper's executor stays small).
    func cadenceCountersForTesting() -> (deferredTurns: Int, foldedSyncs: Int, overdueFoldedSyncs: Int, lateFoldedSyncs: Int, ticksStarted: Int64) {
        (inTurnDeferredTurns, foldedSyncs, overdueFoldedSyncs, lateFoldedSyncs, nextTickId)
    }

    /// Tests only: one sync loop iteration (`runSync`), as the loop runs it.
    func runSyncLoopIterationForTesting() async {
        await runSync()
    }

    /// Tests only: one sync loop iteration that reads `now` as its clock for the coincident-sync
    /// check, so a test decides fold and overdue without depending on scheduling.
    func runSyncLoopIterationForTesting(at now: ContinuousClock.Instant) async {
        syncClockForTesting = now
        defer { syncClockForTesting = nil }
        await runSync()
    }

    /// Tests only: the clock `runSync` reads for the coincident-sync check, when set.
    private var syncClockForTesting: ContinuousClock.Instant?

    /// Tests only: one `stepTickOnce` whose tick turn reads `now` as its start, for the folded
    /// sync's lateness (#232).
    func stepTickOnceForTesting(at now: ContinuousClock.Instant) async {
        tickClockForTesting = now
        defer { tickClockForTesting = nil }
        await stepTickOnce()
    }

    /// Tests only: the clock a tick turn reads as its start, when set.
    private var tickClockForTesting: ContinuousClock.Instant?

    /// Tests only: the sequences of the queued inputs, in queue order.
    func pendingItemSequencesForTesting() -> [Int64] {
        pendingItems.map(\.sequence)
    }

    /// Tests only: how many input-turn outcomes are kept for callers (`inputTurnResults`).
    func inputTurnResultCountForTesting() -> Int {
        inputTurnResults.count
    }

    /// Whether this keeper runs its sync phases in its turns (tests and diagnostics).
    public func isUsingInTurnSync() -> Bool {
        usesInTurnSync
    }

    // MARK: Debug freeze state (see `debugFreeze(generation:timeout:)`)

    /// While true, tick and sync bodies do not start and tickless inputs are held.
    private var debugFrozen = false
    /// Tickless inputs waiting for `debugResume()`.
    private var debugHeldInputs: [CheckedContinuation<Void, Never>] = []
    /// Tick bodies and tickless input processing currently running.
    private var debugInFlightWork = 0
    /// `debugFreeze` callers waiting for the drain, by waiter ID (resumed on drain, release or deadline).
    private var debugDrainWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var debugNextWaiterID: UInt64 = 0
    /// Generation of the freeze in effect, if any.
    private var debugActiveGeneration: UInt64?
    /// Highest generation released by `debugResume(generation:)`; such a generation cannot freeze again.
    private var debugReleasedGeneration: UInt64 = 0

    // Use public system IDs from LandContext
    private let systemPlayerID = LandContext.systemPlayerID
    private let systemClientID = LandContext.systemClientID
    private let systemSessionID = LandContext.systemSessionID

    /// Initializes a new LandKeeper with the given definition and initial state.
    ///
    /// - Parameters:
    ///   - definition: The Land definition containing all handlers and configuration.
    ///   - initialState: The initial state of the Land.
    ///   - mode: The execution mode (live or re-evaluation). Defaults to .live.
    ///   - reevaluationSource: Optional re-evaluation source. Required when mode is .reevaluation.
    ///   - reevaluationSink: Optional sink for emitted events. Used when mode is .reevaluation.
    ///   - reevaluationOutputMode: When mode is .reevaluation, controls whether emitted events go to sink only (.sinkOnly) or both transport and sink (.transportAndSink). Defaults to .sinkOnly.
    ///   - enableLoopPhaseOffset: Delay the first tick and the first sync by a per-land offset in
    ///     `[0, min(interval, 100 ms))` (`LandLoopPhase`), keeping the period, so lands created together do not
    ///     run their loops in phase. Live mode only. Defaults to on unless
    ///     `LAND_LOOP_PHASE_OFFSET` is false.
    ///   - landID: The land instance ID (e.g. "counter:550e8400-..."), when known at creation.
    ///     Set before the eager initialization can start, so OnInitialize, the default RNG seed
    ///     and the loop phase offset all use the instance ID instead of the land type. Without
    ///     it, `setLandID(_:)` sets the ID later, racing with that initialization.
    ///   - transport: Optional transport interface for sending events and syncing state.
    ///                If not provided, operations will be no-ops (useful for testing).
    ///   - logger: Optional logger instance. If not provided, a default logger will be created.
    public init(
        definition: LandDefinition<State>,
        initialState: State,
        mode: LandMode = .live,
        reevaluationSource: (any ReevaluationSource)? = nil,
        reevaluationSink: (any ReevaluationSink)? = nil,
        reevaluationOutputMode: ReevaluationOutputMode = .sinkOnly,
        services: LandServices = LandServices(),
        enableLiveStateHashRecording: Bool = false,
        autoStartLoops: Bool = true,
        enableLoopPhaseOffset: Bool = LandLoopPhase.isEnabled(),
        landID: String? = nil,
        transport: LandKeeperTransport? = nil,
        logger: Logger? = nil
    ) {
        self.definition = definition
        self.actualLandID = landID
        state = initialState
        self.mode = mode
        self.reevaluationSink = reevaluationSink
        self.reevaluationOutputMode = reevaluationOutputMode

        // Ensure DeterministicRngService is always registered for deterministic behavior
        // If not provided, seed it from the instance ID when known, else from definition.id
        // (setLandID(_:) replaces a definition.id seed later).
        var resolvedServices = services
        if resolvedServices.get(DeterministicRngService.self) == nil {
            let seed = DeterministicSeed.fromLandID(landID ?? definition.id)
            let rngService = DeterministicRngService(seed: seed)
            resolvedServices.register(rngService, as: DeterministicRngService.self)
        }
        self.services = resolvedServices

        self.transport = transport
        self.transportRecordsFolds = transport?.recordsInTurnSyncFolds ?? false
        self.autoStartLoops = autoStartLoops
        // Live lands only: re-evaluation replays recorded ticks, its timing is not live load.
        self.enableLoopPhaseOffset = (mode == .live) ? enableLoopPhaseOffset : false
        self.enableLiveStateHashRecording = (mode == .live) ? enableLiveStateHashRecording : false
        let resolvedLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "LandKeeper"
        )
        self.logger = resolvedLogger

        // Initialize recorder if in live mode AND recording is enabled
        // This prevents unnecessary recorder creation in load tests or when recording is not needed
        if mode == .live && enableLiveStateHashRecording {
            let recorder = ReevaluationRecorder(flushInterval: 60)
            reevaluationRecorder = recorder

            // Register recorder service
            resolvedServices.register(
                ReevaluationRecorderService(recorder: recorder, submissions: recorderSubmissions),
                as: ReevaluationRecorderService.self
            )
            self.services = resolvedServices
        }

        // Initialize source if in re-evaluation mode
        if mode == .reevaluation {
            self.reevaluationSource = reevaluationSource
        }

        // Execute OnInitialize handler and then start tick/sync loops.
        // Initialization is performed lazily (first entry point call) to avoid escaping self in init.

        // Kick off initialization eagerly to preserve existing semantics:
        // - OnInitialize runs when Land is created
        // - Tick/sync loops start automatically when configured
        // A failed initialization (#104) tears the land down itself; its callers get the error.
        Task { [weak self] in
            guard let self else { return }
            try? await self.ensureInitialized()
        }
    }

    /// Waits until OnInitialize has run (re-evaluation: before the first tick is stepped).
    /// Waits for the initialization (re-evaluation). A failed one is not reported here: re-
    /// evaluation replays recorded resolver outputs, so its initialization has no deadline.
    package func awaitInitialization() async {
        try? await ensureInitialized()
    }

    /// Runs the initialization once; every caller waits for it. Throws `LandInitializationError`
    /// if it failed (#104), to this caller and every later one.
    private func ensureInitialized() async throws {
        if let initializationFailure { throw initializationFailure }
        if didInitialize { return }
        if let task = initializationTask {
            await task.value
            if let initializationFailure { throw initializationFailure }
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performInitialization()
        }
        initializationTask = task
        await task.value
        initializationTask = nil
        didInitialize = true
        if let initializationFailure { throw initializationFailure }
    }

    /// `ensureInitialized` for a join: a failed initialization is a retryable
    /// `JoinError.landShuttingDown` (JOIN_DENIED, "retry the join"), as for a land closing. The
    /// land is being torn down, so a retry gets a new one.
    private func ensureInitializedForJoin() async throws {
        do {
            try await ensureInitialized()
        } catch {
            throw JoinError.landShuttingDown
        }
    }

    /// Tears the land down after its initialization failed (#104): the normal drain, without the
    /// destroy handlers (`initializationFailure` is set). Started from `performInitialization`,
    /// in a Task of its own: the drain's `forceShutdown` path would otherwise wait for the
    /// initialization it is part of.
    private func tearDownAfterFailedInitialization() async {
        players.removeAll()
        dropPendingInputs(reason: "initialization failed")
        await shutdownIfIdle(cause: .initializationFailed)
    }

    /// Re-evaluation of a record with an initialize record (format 2.1): OnInitialize runs here,
    /// before tick 0, as in the live run: at the recorded sequence, at tick -1 and with the
    /// recorded resolver outputs. Its events are flushed at tick -1 for the initialize check.
    private func replayInitializeBeforeTickZero() async {
        guard mode == .reevaluation,
              let source = reevaluationSource,
              let handler = definition.lifetimeHandlers.onInitialize,
              let record = try? await source.getInitializeRecord(),
              let recorded = try? await source.getLifecycleEvents(for: 0)
                .first(where: { $0.kind == LifecycleKind.initialize.rawValue })
        else { return }
        var resolverOutputs: [String: any ResolverOutput] = [:]
        for (key, output) in recorded.resolverOutputs {
            resolverOutputs[key] = AnyCodableResolverOutput(typeIdentifier: output.typeIdentifier, value: output.value)
        }
        outputCollector.nextSequence = record.sequence
        _ = outputCollector.takeNextSequence()
        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID,
            tickId: lastCommittedTickId,
            resolverOutputs: resolverOutputs
        )
        do {
            try withMutableStateSync(throwWriteKey: nil) { state in
                try handler(&state, ctx)
            }
        } catch {
            logger.error("❌ OnInitialize handler failed during re-evaluation", metadata: [
                "error": .string(String(describing: error)),
            ])
        }
        replayedInitializeBeforeTickZero = true
        await flushOutputs(forTick: lastCommittedTickId)
    }

    /// Whether a throwing OnInitialize resolver group fails the initialization (#238): with
    /// `.failLand`, unless it is a cancellation while the land is shutting down. A cancellation
    /// a resolver raises for its own reasons (a cancelled HTTP request) follows the policy.
    ///
    /// The exemption is defensive: today no shutdown reaches a running initialization.
    /// `forceShutdown` waits for it, the empty-room timer is scheduled only after a leave or a
    /// failed join (both wait for it), and nothing cancels the initialization's task.
    static func initializeResolverFailureFailsLand(
        _ error: any Error,
        policy: InitializeResolverFailure,
        shuttingDown: Bool
    ) -> Bool {
        guard policy == .failLand else { return false }
        return !(shuttingDown && ResolverExecutionError.isCancellation(error))
    }

    private func performInitialization() async {
        if mode == .reevaluation {
            await replayInitializeBeforeTickZero()
        }
        // Execute OnInitialize immediately in live mode (preserve existing semantics).
        // Record it as a lifecycle event under tick 0 so replay can apply it deterministically
        // before the first tick handler runs.
        if mode == .live, let handler = definition.lifetimeHandlers.onInitialize {
            let sequence = outputCollector.takeNextSequence()

            var ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID,
                tickId: lastCommittedTickId
            )

            // Execute resolvers in parallel if any are declared
            if !definition.lifetimeHandlers.onInitializeResolverExecutors.isEmpty {
                let resolverContext = ResolverContext(
                    landContext: ctx,
                    actionPayload: nil,
                    eventPayload: nil,
                    currentState: state
                )
                do {
                    ctx = try await ResolverExecutor.executeInitializeResolvers(
                        executors: definition.lifetimeHandlers.onInitializeResolverExecutors,
                        resolverContext: resolverContext,
                        landContext: ctx
                    )
                } catch {
                    if case ResolverExecutionError.timedOut = error {
                        // Timed out (#104): the initialization fails. OnInitialize doesn't run,
                        // and the land is torn down; its waiters get the error from
                        // `ensureInitialized`.
                        logger.error("❌ OnInitialize resolvers timed out: the land is torn down", metadata: [
                            "error": .string(String(describing: error)),
                        ])
                        initializationFailure = LandInitializationError(underlying: error)
                        Task { await self.tearDownAfterFailedInitialization() }
                        return
                    }
                    if Self.initializeResolverFailureFailsLand(
                        error,
                        policy: definition.lifetimeHandlers.onInitializeResolverFailure,
                        shuttingDown: isDraining || Task.isCancelled
                    ) {
                        // A resolver threw, with `.failLand` (#238): the same as a timeout.
                        ResolverDeadline.metrics.noteInitFailed()
                        logger.error("❌ OnInitialize resolvers failed: the land is torn down", metadata: [
                            "error": .string(String(describing: error)),
                        ])
                        initializationFailure = LandInitializationError(underlying: error)
                        Task { await self.tearDownAfterFailedInitialization() }
                        return
                    }
                    // `.continue`, or cancelled by the land's shutdown: OnInitialize runs without
                    // the group's outputs.
                    logger.error("❌ OnInitialize resolvers failed", metadata: [
                        "error": .string(String(describing: error)),
                    ])
                }
            }

            do {
                // The land runs on with the state OnInitialize left: the check applies.
                try withMutableStateSync(throwWriteKey: "OnInitialize") { state in
                    try handler(&state, ctx)
                }
            } catch {
                logger.error("❌ OnInitialize handler failed", metadata: [
                    "error": .string(String(describing: error)),
                ])
            }
            let initializeIsTurn = usesInTurnSync
            // Recorded in the same synchronous segment as the state write: sync outputs before
            // this point read the state before OnInitialize, outputs after it the state after.
            let initializeRecord = reevaluationRecorder == nil ? nil : makeInitializeRecord(
                sequence: sequence,
                tickId: ctx.tickId ?? lastCommittedTickId
            )
            let initializeMarker = initializeIsTurn && reevaluationRecorder != nil
                ? ReevaluationRecordedSyncMarker(kind: .initialize, streamIndex: takeSyncStreamIndex(), sequence: sequence)
                : nil
            // In-turn sync: OnInitialize is a turn; its events and sync request go out in it.
            if initializeIsTurn, let transport {
                let emitted = takeEmittedEvents(forTick: ctx.tickId ?? lastCommittedTickId)
                let wantsSync = takeSyncRequest(forTick: ctx.tickId ?? lastCommittedTickId, applied: nil)
                runTurnOutputs(transport: transport, events: emitted, wantsSync: wantsSync)
            }

            if let recorder = reevaluationRecorder {
                let resolverOutputsDict = ctx.getAllResolverOutputs().mapValues { output in
                    ReevaluationRecordedResolverOutput(
                        typeIdentifier: String(describing: type(of: output)),
                        value: AnyCodable(output)
                    )
                }
                let recorded = ReevaluationRecordedLifecycleEvent(
                    kind: LifecycleKind.initialize.rawValue,
                    sequence: sequence,
                    tickId: 0,
                    playerID: nil,
                    clientID: nil,
                    sessionID: nil,
                    deviceID: nil,
                    isGuest: nil,
                    metadata: [:],
                    resolverOutputs: resolverOutputsDict,
                    resolvedAtTick: lastCommittedTickId
                )
                if initializeIsTurn {
                    // OnInitialize's server events belong to tick -1, which no frame's
                    // `serverEvents` records; the initialize record keeps them for verification.
                    await submitTurnRecord(ReevaluationTickRecord(
                        tickId: 0,
                        lifecycleEvents: [recorded],
                        syncMarkers: initializeMarker.map { [$0] } ?? [],
                        initialize: initializeRecord
                    ))
                } else {
                    await recorder.record(
                        tickId: 0,
                        actions: [],
                        clientEvents: [],
                        lifecycleEvents: [recorded]
                    )
                    // A tickless land's OnInitialize is one turn record (#327).
                    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, initialize: initializeRecord), endsTurn: isTickless)
                }
            }
        }

        // Then, start tick and sync loops if configured (only after OnInitialize completes)
        guard autoStartLoops else { return }
        let tickInterval = definition.lifetimeHandlers.tickInterval
        let syncInterval = definition.lifetimeHandlers.syncInterval

        // Start tick loop if configured
        if let interval = tickInterval,
           definition.lifetimeHandlers.tickHandler != nil
        {
            await configureTickLoop(interval: interval)
        }

        // Start sync loop: use configured interval, or fallback to tick interval if not configured
        let effectiveSyncInterval: Duration?
        if let sync = syncInterval {
            effectiveSyncInterval = sync
        } else if let tick = tickInterval {
            // Auto-configure sync to match tick interval if sync is not explicitly set
            effectiveSyncInterval = tick
            logger.warning(
                "⚠️ Sync interval not configured for land '\(definition.id)'. Auto-configuring sync to match tick interval (\(tick)). Consider explicitly setting StateSync(every:) in Lifetime block for better control.",
                metadata: [
                    "landID": .string(definition.id),
                    "tickInterval": .string("\(tick)"),
                    "autoSyncInterval": .string("\(tick)"),
                ]
            )
        } else {
            effectiveSyncInterval = nil
        }

        if let interval = effectiveSyncInterval {
            await configureSyncLoop(interval: interval)
        }
    }

    /// Returns the current state snapshot.
    ///
    /// This is a read-only view of the state. Mutations should be done through action/event handlers.
    ///
    /// Note: This method does not check sync lock. For sync operations, use `beginSync(clearDirtyFlags:)` instead.
    public func currentState() -> State {
        state
    }

    /// Begin a sync operation, taking a snapshot of current state.
    ///
    /// For the sync pipeline only; use `currentState()` to read the state.
    ///
    /// **Simplified Model**: Sync uses snapshot model - it takes a snapshot at the start
    /// and works with that snapshot. Mutations are NOT blocked during sync.
    ///
    /// **Dirty flags**: when `clearDirtyFlags` is `true`, the live state's dirty flags are cleared
    /// in the same actor turn that takes the snapshot. The snapshot keeps its own dirty flags (they
    /// live in value types), so the sync cycle still sees every change since the previous clearing
    /// cycle, while any mutation that runs after this call (the sync cycle awaits, and actions or
    /// ticks can run on this actor meanwhile) stays dirty for the next cycle.
    ///
    /// - Parameter clearDirtyFlags: Required, so every caller decides. Pass `true` only for cycles
    ///   that diff every synced field. Pass `false` for partial cycles (e.g. broadcast-only) and
    ///   when dirty tracking is disabled.
    /// - Returns: The current state snapshot if sync can proceed, `nil` if another sync is already in progress (deduplication).
    ///   A rejected call leaves the dirty flags untouched.
    /// - Important: Always call `endSync()` after sync completes, even if an error occurs.
    ///   Flags cleared here are not restored if the cycle fails; the transport adapter then runs
    ///   its next cycle as a recovery cycle (`.all` extraction), which does not depend on them.
    ///
    /// **Why snapshot model works**:
    /// - Each sync gets a consistent snapshot (actor serialization ensures this)
    /// - Mutations can proceed concurrently (they'll be included in next sync)
    /// - No blocking = better performance and simpler code
    ///
    /// Example:
    /// ```swift
    /// guard let state = await keeper.beginSync(clearDirtyFlags: true) else {
    ///     // Another sync in progress, skip this one (deduplication)
    ///     return
    /// }
    /// defer { await keeper.endSync() }
    /// // ... perform sync operations with state snapshot ...
    /// ```
    public func beginSync(clearDirtyFlags: Bool) -> State? {
        guard !isSyncing else {
            return nil // Deduplication: skip concurrent sync requests
        }
        isSyncing = true
        let snapshot = state
        if clearDirtyFlags {
            state.clearDirty()
        }
        return snapshot
    }

    /// `beginSync`, with where its copy was taken (`SyncReadPosition`), from the same job.
    package func beginSyncLocated(clearDirtyFlags: Bool) -> (state: State, position: SyncReadPosition)? {
        let position = syncReadPosition()
        return beginSync(clearDirtyFlags: clearDirtyFlags).map { ($0, position) }
    }

    /// `currentState()`, with where it was read, from the same job.
    package func currentStateLocated() -> (state: State, position: SyncReadPosition) {
        (state, syncReadPosition())
    }

    /// End a sync operation, releasing the sync flag.
    ///
    /// This must be called after `beginSync(clearDirtyFlags:)` to allow new sync requests.
    /// It does not touch dirty flags: those are cleared by `beginSync(clearDirtyFlags:)`, so
    /// mutations made while the sync was in flight stay dirty for the next cycle.
    public func endSync() {
        isSyncing = false
        // A turn found this cycle in flight and left its sync phase to a sync-only turn now.
        if syncOnlyTurnAfterLegacyCycle {
            syncOnlyTurnAfterLegacyCycle = false
            Task { [weak self] in
                await self?.runSyncOnlyTurnIfInTurn()
            }
        }
    }

    /// End a sync operation, releasing the sync flag.
    ///
    /// - Parameter clearDirtyFlags: Ignored. Pass the clearing choice to `beginSync(clearDirtyFlags:)`.
    @available(*, deprecated, message: "pass clearDirtyFlags to beginSync(clearDirtyFlags:); call endSync()")
    public func endSync(clearDirtyFlags: Bool) {
        endSync()
    }

    /// Whether this keeper syncs the land periodically on its own: its loops auto-start and either
    /// the tick loop is configured (`tickInterval` and `tickHandler`) or a sync loop runs (an explicit
    /// `syncInterval`, or the tick interval as fallback). Mirrors the loop setup in
    /// `performInitialization`. When `false`, the land syncs only when someone requests it.
    public nonisolated var hasPeriodicSync: Bool {
        guard autoStartLoops else { return false }
        let handlers = definition.lifetimeHandlers
        let tickLoop = handlers.tickInterval != nil && handlers.tickHandler != nil
        let syncLoop = handlers.syncInterval != nil || handlers.tickInterval != nil
        return tickLoop || syncLoop
    }

    /// Returns the current number of players in the land.
    ///
    /// This counts unique players (not connections), as a player can have multiple connections.
    public func playerCount() -> Int {
        players.count
    }

    /// Get the ReevaluationRecorder instance (for testing/debugging).
    /// Returns nil if not in live mode or recorder is not available.
    public func getReevaluationRecorder() -> ReevaluationRecorder? {
        reevaluationRecorder
    }

    /// Get the current LandMode (for testing/debugging).
    public func getMode() -> LandMode {
        mode
    }

    deinit {
        tickTask?.cancel()
        syncTask?.cancel()
        destroyTask?.cancel()
    }

    // MARK: - Debug Freeze

    /// Pause the land for a debug state check and wait until in-flight work has finished.
    ///
    /// While frozen:
    /// - no tick body and no sync-loop body starts;
    /// - in tickless lands, `handleActionEnvelope` and `handleClientEvent` wait until the freeze
    ///   is released (in tick lands they only queue, and ticks do not run);
    /// - joins and leaves still run (callers detect them separately);
    /// - server inputs are accepted with their sequence and held until the resume. In a
    ///   tickless land a join or leave during the freeze is applied before a held server input
    ///   with a lower sequence; the record keeps the applied order, and replay follows it.
    ///
    /// The freeze belongs to `generation` (the caller's, increasing per freeze). A generation that
    /// was already released does not freeze again, so a late call cannot re-pause the land.
    ///
    /// - Returns: `true` once tick bodies and tickless input processing that were already running
    ///   (including their resolvers) have finished; `false` when `timeout` passes first or the
    ///   generation is released meanwhile. The land stays frozen until
    ///   `debugResume(generation:)` either way. Debug tooling only; the transport layer owns
    ///   reference counting.
    public func debugFreeze(generation: UInt64, timeout: Duration) async -> Bool {
        guard generation > debugReleasedGeneration else { return false }
        debugFrozen = true
        debugActiveGeneration = generation
        // A pending fold's tick turn doesn't run while frozen; reported after the resume, the
        // freeze would count as tick lateness (#232). The next sync iteration folds again.
        pendingFold = nil

        let deadline = ContinuousClock.now + timeout
        while debugInFlightWork > 0, debugActiveGeneration == generation {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            debugNextWaiterID &+= 1
            let waiterID = debugNextWaiterID
            let timer = Task { [weak self] in
                try? await safeTaskSleep(for: remaining)
                await self?.debugWakeDrainWaiter(waiterID)
            }
            await withCheckedContinuation { continuation in
                debugDrainWaiters[waiterID] = continuation
                let watchers = freezeWaitWatchersForTesting
                freezeWaitWatchersForTesting.removeAll()
                watchers.forEach { $0.resume() }
            }
            timer.cancel()
        }
        return debugActiveGeneration == generation && debugInFlightWork == 0
    }

    /// Release the freeze of `generation`: held tickless inputs continue and ticks start again.
    /// A stale generation (not the one in effect) only marks that generation released.
    public func debugResume(generation: UInt64) {
        debugReleasedGeneration = max(debugReleasedGeneration, generation)
        guard debugActiveGeneration == generation else { return }
        debugActiveGeneration = nil
        debugFrozen = false
        releaseServerInputsHeldWhileFrozen()
        let held = debugHeldInputs
        debugHeldInputs.removeAll()
        held.forEach { $0.resume() }
        // Waiters of this generation re-check and return false.
        let waiters = debugDrainWaiters
        debugDrainWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    /// Whether a debug freeze is in effect.
    public func isDebugFrozen() -> Bool {
        debugFrozen
    }

    /// The most recent committed tick ID (-1 before the first tick).
    public func debugLastCommittedTickId() -> Int64 {
        lastCommittedTickId
    }

    /// Holds tickless intake while frozen. Returns when the freeze is released or the drain
    /// starts (`releaseHeldInputsForDrain`); the intake then re-checks `rejectIfLandClosed`.
    private func debugWaitWhileFrozen() async {
        while debugFrozen, !isDraining {
            await withCheckedContinuation { continuation in
                debugHeldInputs.append(continuation)
                inTurnProbeForTesting?("input-held-frozen")
            }
        }
    }

    private func debugBeginWork() {
        debugInFlightWork += 1
    }

    private func debugEndWork() {
        debugInFlightWork -= 1
        guard debugInFlightWork == 0, !debugDrainWaiters.isEmpty else { return }
        let waiters = debugDrainWaiters
        debugDrainWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    private func debugWakeDrainWaiter(_ waiterID: UInt64) {
        debugDrainWaiters.removeValue(forKey: waiterID)?.resume()
    }

    // MARK: - Player Lifecycle

    /// Handles a player joining the Land (legacy method for backward compatibility).
    ///
    /// This method creates a PlayerSession internally and calls the new join method.
    /// For new code, consider using the overload that accepts PlayerSession.
    ///
    /// - Parameters:
    ///   - playerID: The player's unique identifier.
    ///   - clientID: The client instance identifier.
    ///   - sessionID: The session/connection identifier.
    ///   - services: Services to inject into the LandContext.
    public func join(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices = LandServices()
    ) async throws {
        try await ensureInitializedForJoin()
        await holds.at(.join)
        // Check for duplicate playerID login (Kick Old strategy)
        if let existingSession = players[playerID], let oldClientID = existingSession.clientID {
            logger.info("Duplicate playerID login detected: \(playerID.rawValue), kicking old client: \(oldClientID.rawValue)")
            // Kick old connection by calling leave
            // This will call OnLeave handler and clean up state
            try await leave(playerID: playerID, clientID: oldClientID, sessionID: existingSession.lastSessionID)
        }

        var session = players[playerID] ?? InternalPlayerSession(services: services)
        let isFirst = session.clientID == nil

        session.clientID = clientID
        session.lastSessionID = sessionID
        session.services = services
        // Checked in the same synchronous segment as the insert: a destruction that started
        // during this join's awaits must not get a player after it stopped the loops.
        guard !isDraining else { throw JoinError.landShuttingDown }
        let entryGeneration = entryGenerations.next()
        session.generation = entryGeneration
        players[playerID] = session

        destroyTask?.cancel()
        destroyTask = nil

        // In reevaluation mode, replay viewers are observers: add to players for sync but skip OnJoin
        // so they are not added to game state (which would create an extra player in the replay).
        guard isFirst, definition.lifetimeHandlers.onJoin != nil, mode != .reevaluation else { return }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
        let sequence = outputCollector.takeNextSequence()

        // Snapshot tick at request time; update after resolver completion for async determinism.
        var resolvedAtTick = lastCommittedTickId
        var resolverOutputs: [String: any ResolverOutput] = [:]

        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onJoinResolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                servicesOverride: services
            )
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: nil,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await executeOnJoinResolvers(
                resolverContext: resolverContext,
                landContext: ctx,
                playerID: playerID,
                entryGeneration: entryGeneration
            )
            resolverOutputs = ctx.getAllResolverOutputs()
            // Bind to the tick that was current when resolvers completed
            resolvedAtTick = lastCommittedTickId
        }

        // Same synchronous segment as the append: a drain that started during the resolvers
        // must not get an OnJoin input after it took the pending inputs. The entry this join
        // inserted goes too (if it is still this join's), so `players` doesn't keep a player
        // that never joined.
        guard !isDraining else {
            if players[playerID]?.generation == entryGeneration {
                players.removeValue(forKey: playerID)
            }
            throw JoinError.landShuttingDown
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: sequence,
                kind: .join,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                deviceID: session.deviceID,
                isGuest: session.isGuest,
                metadata: session.metadata,
                resolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick,
                entryGeneration: entryGeneration
            )
        )
        pendingItems.append(pendingItem)

        // If there's no tick handler, process lifecycle immediately (backward-compatible mode)
        if definition.lifetimeHandlers.tickHandler == nil {
            if usesInTurnSync {
                _ = try await awaitInputTurn(sequence: sequence)
            } else {
                _ = try await runLegacyPass(for: sequence)
            }
        }
    }

    /// Handles a player joining the Land with session-based validation.
    ///
    /// This method supports the CanJoin handler for pre-validation before adding
    /// the player to the authoritative state.
    ///
    /// - Parameters:
    ///   - session: The player session information.
    ///   - clientID: The client instance identifier.
    ///   - sessionID: The session/connection identifier.
    ///   - services: Services to inject into the LandContext.
    /// - Returns: JoinDecision indicating if the join was allowed or denied.
    /// - Throws: Errors from the CanJoin handler if join validation fails.
    public func join(
        session: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices
    ) async throws -> JoinDecision {
        try await joinReportingAdmission(
            session: session,
            clientID: clientID,
            sessionID: sessionID,
            services: services,
            admitThroughTransport: false
        ).decision
    }

    /// What `joinReportingAdmission` did.
    package struct JoinOutcome: Sendable {
        package let decision: JoinDecision
        /// The transport admitted the session inside the join
        /// (`LandKeeperTransport.admitJoiningSession` returned `true`). When `false`, the caller
        /// admits it after the join returns, so a session is admitted exactly once.
        package let admitted: Bool
    }

    /// `join(session:clientID:sessionID:services:)`, and, when `admitThroughTransport` and this
    /// keeper's turns run the sync phase in the turn (`usesInTurnSync`), the transport's
    /// `admitJoiningSession` in the same synchronous segment as the player's insert (or as its
    /// OnJoin input's append, for a first join with OnJoin). Off that path, or for a non-live
    /// keeper, nothing is admitted here (`admitted == false`).
    package func joinReportingAdmission(
        session: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices,
        admitThroughTransport: Bool
    ) async throws -> JoinOutcome {
        try await ensureInitializedForJoin()
        // Call CanJoin handler if defined
        var decision: JoinDecision = .allow(playerID: PlayerID(session.playerID))

        if let canJoinHandler = definition.lifetimeHandlers.canJoin {
            var ctx = makeContext(
                playerID: PlayerID("_pending"), // Temporary ID for validation
                clientID: clientID,
                sessionID: sessionID,
                servicesOverride: services
            )

            // Execute resolvers in parallel if any are declared
            if !definition.lifetimeHandlers.canJoinResolverExecutors.isEmpty {
                let resolverContext = ResolverContext(
                    landContext: ctx,
                    actionPayload: nil,
                    eventPayload: nil,
                    currentState: state
                )
                ctx = try await ResolverExecutor.executeResolvers(
                    executors: definition.lifetimeHandlers.canJoinResolverExecutors,
                    resolverContext: resolverContext,
                    landContext: ctx
                )
            }

            // Execute handler synchronously (resolvers already executed above)
            decision = try canJoinHandler(state, session, ctx)
        }

        // If denied, return early
        guard case let .allow(playerID) = decision else {
            return JoinOutcome(decision: decision, admitted: false)
        }

        // Check maxPlayers limit after CanJoin handler (using the playerID returned by CanJoin)
        // Skip check if player is already in the room (reconnection scenario)
        let isReconnection = players[playerID] != nil

        if let maxPlayers = definition.config.maxPlayers, !isReconnection {
            let currentPlayerCount = players.count
            guard currentPlayerCount < maxPlayers else {
                logger.info("Join rejected: room is full", metadata: [
                    "currentPlayers": .stringConvertible(currentPlayerCount),
                    "maxPlayers": .stringConvertible(maxPlayers),
                ])
                throw JoinError.roomIsFull
            }
        }

        await holds.at(.join)
        // Check for duplicate playerID login (Kick Old strategy)
        if let existingSession = players[playerID], let oldClientID = existingSession.clientID {
            logger.info("Duplicate playerID login detected: \(playerID.rawValue), kicking old client: \(oldClientID.rawValue)")
            // Kick old connection by calling leave
            // This will call OnLeave handler and clean up state
            try await leave(playerID: playerID, clientID: oldClientID, sessionID: existingSession.lastSessionID)
        }

        // Proceed with join
        var playerSession = players[playerID] ?? InternalPlayerSession(
            services: services,
            deviceID: session.deviceID,
            isGuest: session.isGuest,
            metadata: session.metadata
        )
        let isFirst = playerSession.clientID == nil

        playerSession.clientID = clientID
        playerSession.lastSessionID = sessionID
        playerSession.services = services
        // Update deviceID, isGuest, and metadata if provided (for reconnection scenarios)
        if let deviceID = session.deviceID {
            playerSession.deviceID = deviceID
        }
        playerSession.isGuest = session.isGuest
        if !session.metadata.isEmpty {
            playerSession.metadata = session.metadata
        }
        // Checked in the same synchronous segment as the insert: a destruction that started
        // during this join's awaits must not get a player after it stopped the loops.
        guard !isDraining else { throw JoinError.landShuttingDown }
        let entryGeneration = entryGenerations.next()
        playerSession.generation = entryGeneration
        players[playerID] = playerSession

        destroyTask?.cancel()
        destroyTask = nil

        // In reevaluation mode, replay viewers are observers: add to players for sync but skip OnJoin
        // so they are not added to game state (which would create an extra player in the replay).
        guard isFirst, definition.lifetimeHandlers.onJoin != nil, mode != .reevaluation else {
            // No OnJoin input: admitted in the same segment as the insert.
            let admitted = admitThroughTransport && admitJoiningInTurn(playerID: playerID, clientID: clientID, sessionID: sessionID, joinSequence: nil).isAdmitted
            return JoinOutcome(decision: decision, admitted: admitted)
        }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
        let sequence = outputCollector.takeNextSequence()

        // Snapshot tick at request time; update after resolver completion for async determinism.
        var resolvedAtTick = lastCommittedTickId
        var resolverOutputs: [String: any ResolverOutput] = [:]

        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onJoinResolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                servicesOverride: services,
                deviceID: session.deviceID,
                isGuest: session.isGuest,
                metadata: session.metadata
            )
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: nil,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await executeOnJoinResolvers(
                resolverContext: resolverContext,
                landContext: ctx,
                playerID: playerID,
                entryGeneration: entryGeneration
            )
            resolverOutputs = ctx.getAllResolverOutputs()
            resolvedAtTick = lastCommittedTickId
        }

        // Same synchronous segment as the append: a drain that started during the resolvers
        // must not get an OnJoin input after it took the pending inputs. The entry this join
        // inserted goes too (if it is still this join's), so `players` doesn't keep a player
        // that never joined.
        guard !isDraining else {
            if players[playerID]?.generation == entryGeneration {
                players.removeValue(forKey: playerID)
            }
            throw JoinError.landShuttingDown
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: sequence,
                kind: .join,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                deviceID: session.deviceID,
                isGuest: session.isGuest,
                metadata: session.metadata,
                resolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick,
                entryGeneration: entryGeneration
            )
        )
        pendingItems.append(pendingItem)
        // Admitted in the same segment as the append, before the OnJoin turn can run.
        let admission: JoinAdmission = admitThroughTransport
            ? admitJoiningInTurn(playerID: playerID, clientID: clientID, sessionID: sessionID, joinSequence: sequence)
            : .notAdmitted
        let admitted = admission.isAdmitted

        // If there's no tick handler, process lifecycle immediately (backward-compatible mode)
        if definition.lifetimeHandlers.tickHandler == nil {
            if admission == .admittedCompletesInTurn {
                // Admitted in the turn: the transport completes the join when a turn consumes
                // the input (`noteJoinInputsConsumed`) and a sync phase commits for it. Nobody
                // awaits the input turn here, so it is scheduled in this segment.
                scheduleInputDrain()
            } else if usesInTurnSync {
                _ = try await awaitInputTurn(sequence: sequence)
            } else {
                _ = try await runLegacyPass(for: sequence)
            }
        }

        return JoinOutcome(decision: decision, admitted: admitted)
    }

    /// Called in the segment where `item`'s handler threw. A join whose OnJoin threw never
    /// completed: its input is removed (so no later pass runs that OnJoin again for a player that
    /// isn't there) and so is the player it inserted, without OnLeave, so the failed join holds
    /// no capacity and doesn't keep the land alive. The player is removed only if it is still
    /// that join's entry (its `generation`). OnJoin's partial state changes are not rolled back (no per-input
    /// savepoints, #87).
    private func discardIfFailedJoin(_ item: PendingItem) {
        guard case let .lifecycle(lifecycle) = item, lifecycle.kind == .join,
              let playerID = lifecycle.playerID else { return }
        pendingItems.removeAll { $0.sequence == lifecycle.sequence }
        if let session = players[playerID], let generation = lifecycle.entryGeneration,
           session.generation == generation {
            players.removeValue(forKey: playerID)
            scheduleDestroyIfNeeded()
        }
        logger.warning("OnJoin threw: the join's input and player were removed", metadata: [
            "playerID": .string(playerID.rawValue),
            "sessionID": .string(lifecycle.sessionID?.rawValue ?? "nil"),
        ])
    }

    /// The transport's admission of a joining session, only on the in-turn path (the transport
    /// shares this keeper's executor, so its synchronous call can't trap). Synchronous: called in
    /// the segment of the state change it belongs to.
    private func admitJoiningInTurn(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        guard usesInTurnSync, let transport else { return .notAdmitted }
        return transport.admitJoiningSession(playerID: playerID, clientID: clientID, sessionID: sessionID, joinSequence: joinSequence)
    }

    /// Reports the join inputs a turn applied to an in-turn transport (`noteJoinInputsConsumed`),
    /// in the segment that applied them. Live keepers only: re-evaluation feeds recorded joins.
    private func noteJoinInputsConsumed(_ results: [JoinInputResult]) {
        guard !results.isEmpty, usesInTurnSync, mode == .live, let transport else { return }
        transport.noteJoinInputsConsumed(results)
    }

    /// Whether the transport has joins that wait for a committed sync phase, read in a turn.
    private var transportHasJoinsAwaitingSync: Bool {
        guard usesInTurnSync, mode == .live, let transport else { return false }
        return transport.hasJoinsAwaitingSync
    }

    /// A sync-only turn for joins that wait for a committed sync phase (#69). Called by the
    /// transport when a join became ready outside a turn (its session registered with the
    /// transport after its OnJoin was consumed). Does nothing when no join waits, so a burst of
    /// such requests shares the first one's turn: it flips every ready join (up to the budget).
    package func requestJoinSyncTurn() async {
        // Draining: the drain fails the waiting joins with `landClosed`, none flips now.
        guard !isDraining, transportHasJoinsAwaitingSync, let transport else { return }
        if hasPeriodicSync {
            // A sync folded into the next tick (`inTurnSyncDue`) must not run ahead of that tick
            // (coincident-sync rule): the tick turn's cadence sync flips the ready joins.
            guard periodicJoinSyncAllowed, !inTurnSyncDue else { return }
            runSyncOnlyTurn(transport: transport, joinSyncOnly: true)
        } else {
            runSyncOnlyTurn(transport: transport)
        }
    }

    /// Whether a land with periodic sync runs a sync phase for its ready joins outside the
    /// cadence now. Not while draining (the drain fails the waiting joins), and not after such a
    /// sync was deferred by writer back-pressure, until a sync commits: the periodic sync
    /// completes them then. So a backlog adds at most one extra deferred turn per episode per
    /// land (`inTurnDeferredTurns`, and the profiler's `syncDeferredTurns`), not one per tick or
    /// per registration.
    private var periodicJoinSyncAllowed: Bool {
        hasPeriodicSync && !isDraining && !joinSyncWaitsForCommit && transportHasJoinsAwaitingSync
    }

    /// Tick turns that ran their sync phase only for ready joins (no sync due by the cadence).
    private(set) var joinSyncTicks = 0

    /// A join-only sync phase was deferred by back-pressure; cleared when a sync phase commits.
    private(set) var joinSyncWaitsForCommit = false

    /// Inputs rejected by `rejectSenderIfSuperseded` so far.
    private(set) var supersededSenderRejections = 0

    /// Intake check for actions and client events (#92, newest wins): rejects a sender only when
    /// the player has an entry and that entry is another client or session, i.e. a newer join
    /// of the player replaced the sender's session. Called on `.live` keepers only (the intake
    /// returns earlier otherwise), at intake. An action's resolvers lie between its intake and
    /// its append; its delivery checks the entry's generation instead (`deliverResolvedAction`).
    ///
    /// Unchanged: a player with no entry (direct callers that send before or without a join),
    /// the system player and client, and a sender matching the entry (a join, then sends with the
    /// same client and session).
    private func rejectSenderIfSuperseded(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        input: String
    ) throws {
        guard playerID != systemPlayerID, clientID != systemClientID,
              let entry = players[playerID] else { return }
        let otherClient = entry.clientID.map { $0 != clientID } ?? false
        let otherSession = entry.lastSessionID.map { $0 != sessionID } ?? false
        guard otherClient || otherSession else { return }
        supersededSenderRejections += 1
        logger.warning("Input rejected: a newer session of the player replaced the sender's", metadata: [
            "playerID": .string(playerID.rawValue),
            "clientID": .string(clientID.rawValue),
            "sessionID": .string(sessionID.rawValue),
            "input": .string(input),
            "rejectedTotal": .stringConvertible(supersededSenderRejections),
        ])
        throw LandInputRejection.senderSuperseded
    }

    /// Intake (and delivery) check: once the drain has started (`isDraining`, set in the same
    /// segment as the emptiness check), no input is accepted, so nothing is appended after the
    /// drain took the pending inputs.
    private func rejectIfLandClosed() throws {
        guard isDraining else { return }
        throw LandInputRejection.landClosed
    }

    /// What an action captured at intake about its sender, checked when its resolvers' result
    /// is delivered (`deliverResolvedAction`).
    struct ActionTicket: Sendable {
        /// The sender's entry generation at intake; `nil` when the player had no entry (direct
        /// callers that send before or without a join) or the sender is exempt (the system
        /// player or client).
        let entryGeneration: Epoch?
    }

    private func actionTicket(for playerID: PlayerID, clientID: ClientID) -> ActionTicket {
        guard playerID != systemPlayerID, clientID != systemClientID else {
            return ActionTicket(entryGeneration: nil)
        }
        return ActionTicket(entryGeneration: players[playerID]?.generation)
    }

    /// Delivers an action whose resolvers finished: the only code that runs after their
    /// await, one synchronous segment. The result is an input like any other; it is validated
    /// against the current state with the intake's ticket, and appended only when it holds:
    /// - no entry at intake: accepted (nothing to compare);
    /// - the sender's entry at intake, the same generation now: accepted;
    /// - the sender's entry at intake, gone or replaced now (the player left, or a newer join
    ///   replaced it): rejected with `LandInputRejection.senderSuperseded`;
    /// - the land draining or shut down now: rejected with `LandInputRejection.landClosed`
    ///   (finalize doesn't remove entries, so the sender check alone would accept it).
    ///
    /// The input is bound to the tick current now (`resolvedAtTick`), so it applies in the
    /// first turn after its resolvers finish, as recorded. A rejected input has taken a
    /// sequence number and is never recorded; replay advances past the gap through the
    /// recorded watermarks.
    private func deliverResolvedAction(
        _ item: PendingActionItem,
        ticket: ActionTicket,
        input: String
    ) throws {
        try validateDelivery(of: item, ticket: ticket, input: input)
        pendingItems.append(.action(PendingActionItem(
            sequence: item.sequence,
            action: item.action,
            actionType: item.actionType,
            playerID: item.playerID,
            clientID: item.clientID,
            sessionID: item.sessionID,
            resolverOutputs: item.resolverOutputs,
            resolvedAtTick: lastCommittedTickId
        )))
        inTurnProbeForTesting?("action-queued")
    }

    /// The delivery checks (`deliverResolvedAction`): the land isn't draining, and the sender's
    /// entry is still the one the ticket names.
    private func validateDelivery(of item: PendingActionItem, ticket: ActionTicket, input: String) throws {
        // The land started draining during the resolvers: nothing is appended any more.
        try rejectIfLandClosed()
        if let generation = ticket.entryGeneration, players[item.playerID]?.generation != generation {
            supersededSenderRejections += 1
            logger.warning("Action rejected at delivery: the sender's entry ended during its resolvers", metadata: [
                "playerID": .string(item.playerID.rawValue),
                "clientID": .string(item.clientID.rawValue),
                "sessionID": .string(item.sessionID.rawValue),
                "input": .string(input),
                "rejectedTotal": .stringConvertible(supersededSenderRejections),
            ])
            throw LandInputRejection.senderSuperseded
        }
    }

    // MARK: - Action jobs

    /// An action whose resolvers run in their own task. Keyed by its sequence.
    private struct ActionJob {
        /// The action as taken in; its resolver outputs are filled in at delivery.
        let item: PendingActionItem
        let ticket: ActionTicket
        let input: String
        var task: Task<Void, Never>?
        /// Its resolvers' abandonment (the caller stopped waiting while they still run). The job
        /// keeps its place in the caps until they end.
        let abandonment: ActionAbandonment
        /// The completion ran; the job stays registered only while its abandoned resolvers run.
        var completed = false
        /// The caller was cancelled while waiting: the completion fails with `CancellationError`
        /// instead of delivering, unless it ran first.
        let callerCancelled = ActionJobCallerCancellation()
        /// Cancelled by the keeper (the sender's entry ended, or the land is draining): its slot
        /// already holds the delivery checks' rejection, and its completion only removes it.
        var cancelledByKeeper = false
    }

    /// The outcome of a job, kept from `submitAction` until `awaitActionResult` reads it. It's
    /// created in the intake's segment, so a reader that arrives after the completion still finds it.
    private struct ActionSlot {
        var result: Result<AnyCodable, any Error>?
        var waiter: CheckedContinuation<AnyCodable, any Error>?
    }

    private var actionJobs: [Int64: ActionJob] = [:]
    private var actionSlots: [Int64: ActionSlot] = [:]
    /// Tests only: waiters for a job to leave the job table (`waitForActionJobsForTesting`).
    private var actionJobRemovalWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    /// Jobs started so far (tests).
    private var actionJobsStarted = 0
    /// Tickless jobs whose in-flight work (`debugBeginWork` at intake) ends when their slot is
    /// filled, on whichever path fills it: so `debugFreeze` waits for their responses.
    private var ticklessJobWork: Set<Int64> = []
    /// Tickless jobs delivered (appended) and not yet applied: the input turn or legacy pass that
    /// applies one fills its slot with the handler's outcome, after the turn's record is in.
    private var ticklessJobTurns: Set<Int64> = []
    #if DEBUG
    /// Debug only: the most recent filled slots, so a second fill is caught even after the
    /// first was read and the slot removed. A bounded ring: memory stays fixed.
    private var filledActionSlotsForAssert: Set<Int64> = []
    private var filledActionSlotsOrderForAssert: [Int64] = []
    private var filledActionSlotsNextForAssert = 0
    private static var filledActionSlotsCapacityForAssert: Int { 1024 }
    #endif

    /// Registers the job and its slot, and starts its resolvers. Called in the intake segment.
    private func startActionJob(
        _ item: PendingActionItem,
        decodedAction: any ActionPayload,
        executors: [any AnyResolverExecutor],
        ticket: ActionTicket,
        input: String
    ) {
        let sequence = item.sequence
        let ctx = makeContext(
            playerID: item.playerID,
            clientID: item.clientID,
            sessionID: item.sessionID,
            tickId: lastCommittedTickId
        )
        let resolverContext = ResolverContext(
            landContext: ctx,
            actionPayload: decodedAction as (any Sendable),
            eventPayload: nil,
            currentState: state
        )
        let abandonment = ActionAbandonment(metrics: ResolverDeadline.metrics) { [weak self] in
            Task { await self?.releaseCompletedActionJob(sequence) }
        }
        actionSlots[sequence] = ActionSlot()
        actionJobs[sequence] = ActionJob(item: item, ticket: ticket, input: input, abandonment: abandonment)
        actionJobsStarted += 1
        let task = Task { [weak self] in
            let resolved: Result<[String: any ResolverOutput], any Error>
            do {
                let outputs = try await ResolverExecutor.executeActionResolvers(
                    executors: executors,
                    resolverContext: resolverContext,
                    landContext: ctx,
                    abandonment: abandonment
                )
                resolved = .success(outputs.getAllResolverOutputs())
            } catch {
                resolved = .failure(error)
            }
            await self?.completeAction(sequence: sequence, resolved: resolved)
        }
        actionJobs[sequence]?.task = task
    }

    /// A job's resolvers finished (or failed, or were cancelled): one synchronous segment after
    /// the hold point. Delivers the result like any input, with the intake's ticket checked
    /// against the current state, and fills the job's slot with the outcome.
    private func completeAction(
        sequence: Int64,
        resolved: Result<[String: any ResolverOutput], any Error>
    ) async {
        await holds.at(.actionComplete)
        guard var job = actionJobs[sequence], !job.completed else { return }
        // The job's place in the caps lasts until its resolvers' task ends.
        if job.abandonment.isRunning {
            job.completed = true
            actionJobs[sequence] = job
        } else {
            removeActionJob(sequence)
        }
        guard !job.cancelledByKeeper else { return }
        let outcome: Result<AnyCodable, any Error>
        switch resolved {
        case .failure(let error):
            outcome = .failure(error)
        case .success where job.callerCancelled.isSet:
            outcome = .failure(CancellationError())
        case .success(let outputs):
            let item = job.item
            do {
                try deliverResolvedAction(
                    PendingActionItem(
                        sequence: item.sequence,
                        action: item.action,
                        actionType: item.actionType,
                        playerID: item.playerID,
                        clientID: item.clientID,
                        sessionID: item.sessionID,
                        resolverOutputs: outputs,
                        resolvedAtTick: item.resolvedAtTick
                    ),
                    ticket: job.ticket,
                    input: job.input
                )
                if definition.lifetimeHandlers.tickHandler == nil {
                    // Tickless: the turn or pass that applies it answers, after its record.
                    // Delivered, it is out of the job table's cancellations (`completed`).
                    ticklessJobTurns.insert(sequence)
                    if usesInTurnSync {
                        scheduleInputDrain()
                    } else {
                        // Only a trigger: it guarantees a pass runs. It's usually empty or
                        // applies other inputs too, since any pass applies every ready input and
                        // another session's pass often gets here first; the pass that applies
                        // this action is the one that answers it.
                        Task { [weak self] in await self?.runTicklessJobPass() }
                    }
                    return
                }
                // Tick land: acknowledged now; the handler runs in a tick.
                outcome = .success(AnyCodable(()))
            } catch {
                outcome = .failure(error)
            }
        }
        fillActionSlot(sequence, with: outcome)
    }

    /// The trigger pass of a tickless job's completion (in-turn sync off).
    private func runTicklessJobPass() async {
        await holds.at(.ticklessJobPass)
        await processPendingActions()
    }

    /// The job leaves the job table (and the caps); test waiters on it resume.
    private func removeActionJob(_ sequence: Int64) {
        actionJobs.removeValue(forKey: sequence)
        actionJobRemovalWaiters.removeValue(forKey: sequence)?.forEach { $0.resume() }
    }

    /// Debug only: remembers a filled slot in the ring, forgetting the oldest once it's full.
    private func rememberFilledSlotForAssert(_ sequence: Int64) {
        #if DEBUG
        let firstFill = filledActionSlotsForAssert.insert(sequence).inserted
        assert(firstFill, "Action job \(sequence)'s slot was filled twice")
        let capacity = Self.filledActionSlotsCapacityForAssert
        if filledActionSlotsOrderForAssert.count < capacity {
            filledActionSlotsOrderForAssert.append(sequence)
        } else {
            filledActionSlotsForAssert.remove(filledActionSlotsOrderForAssert[filledActionSlotsNextForAssert])
            filledActionSlotsOrderForAssert[filledActionSlotsNextForAssert] = sequence
            filledActionSlotsNextForAssert = (filledActionSlotsNextForAssert + 1) % capacity
        }
        #endif
    }

    /// The abandoned resolvers of a completed job ended: it leaves the caps.
    private func releaseCompletedActionJob(_ sequence: Int64) {
        guard actionJobs[sequence]?.completed == true else { return }
        removeActionJob(sequence)
    }

    /// The caps on action jobs (`ActionJobLimits`), checked at intake before the sequence is
    /// taken: the session's jobs still registered (abandoned ones included), and the process's
    /// abandoned action jobs.
    private func rejectIfOverActionJobLimits(sessionID: SessionID, input: String) throws {
        let metrics = ResolverDeadline.metrics
        if let limit = ActionJobLimits.inFlightPerSession,
           actionJobs.values.lazy.filter({ $0.item.sessionID == sessionID }).count >= limit {
            metrics.noteInFlightLimitRejection()
            logger.warning("Action rejected: the session's in-flight limit is reached", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "input": .string(input),
                "limit": .stringConvertible(limit),
            ])
            throw ActionLimitRejection.inFlightLimit(limit: limit)
        }
        if let limit = ActionJobLimits.abandonedActions, metrics.snapshot.abandonedActions >= limit {
            metrics.noteAbandonedLimitRejection()
            logger.warning("Action rejected: the process's abandoned-resolver limit is reached", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "input": .string(input),
                "limit": .stringConvertible(limit),
            ])
            throw ActionLimitRejection.abandonedResolverLimit(limit: limit)
        }
    }

    /// Fills the job's slot with its one outcome. A tickless job's in-flight work ends here, on
    /// every path: the applying turn, a rejection or failure at completion, a cancellation, the drain.
    private func fillActionSlot(_ sequence: Int64, with outcome: Result<AnyCodable, any Error>) {
        if ticklessJobWork.remove(sequence) != nil {
            debugEndWork()
        }
        rememberFilledSlotForAssert(sequence)
        guard var slot = actionSlots[sequence] else { return }
        if let waiter = slot.waiter {
            actionSlots.removeValue(forKey: sequence)
            waiter.resume(with: outcome)
        } else {
            slot.result = outcome
            actionSlots[sequence] = slot
        }
    }

    /// The outcome of the job `submitAction` returned `.pending(sequence)` for: the ACK, or the
    /// rejection or resolver error. Read once; the slot is removed after, and a second read (or
    /// one for a sequence that had no job) throws `ActionResultUnavailable`.
    ///
    /// Cancelling the caller cancels the job's task directly (no actor hop) and marks the job,
    /// so a completion that hasn't run yet fails with `CancellationError` instead of delivering.
    package func awaitActionResult(sequence: Int64) async throws -> AnyCodable {
        let task = actionJobs[sequence]?.task
        let callerCancelled = actionJobs[sequence]?.callerCancelled
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnyCodable, any Error>) in
                guard var slot = actionSlots[sequence], slot.waiter == nil else {
                    continuation.resume(throwing: ActionResultUnavailable(sequence: sequence))
                    return
                }
                // Cancelled before the wait began: same segment as the check below, so a
                // completion can't run in between.
                if Task.isCancelled {
                    callerCancelled?.set()
                    task?.cancel()
                }
                if let result = slot.result {
                    actionSlots.removeValue(forKey: sequence)
                    continuation.resume(with: result)
                    return
                }
                slot.waiter = continuation
                actionSlots[sequence] = slot
            }
        } onCancel: {
            // Synchronous: once `cancel()` returns, a completion that hasn't run yet won't deliver.
            callerCancelled?.set()
            task?.cancel()
        }
    }

    /// Cancels the jobs whose ticket names the entry `generation` (a leave ended it). Only the
    /// ticket selects them, never the player or session key: a newer entry's jobs stay.
    private func cancelActionJobs(ofEntryGeneration generation: Epoch) {
        for (sequence, job) in actionJobs where job.ticket.entryGeneration == generation {
            cancelActionJob(sequence)
        }
    }

    /// Cancels every job: the land is draining.
    private func cancelAllActionJobs() {
        for sequence in actionJobs.keys {
            cancelActionJob(sequence)
        }
    }

    /// The caller gets the delivery checks' rejection now (they also count and log it), not
    /// when the resolvers end; the job stays registered until its task ends.
    private func cancelActionJob(_ sequence: Int64) {
        // A completed job (kept only while its abandoned resolvers run) already has its outcome.
        guard let job = actionJobs[sequence], !job.cancelledByKeeper, !job.completed else { return }
        actionJobs[sequence]?.cancelledByKeeper = true
        let outcome: Result<AnyCodable, any Error>
        do {
            try validateDelivery(of: job.item, ticket: job.ticket, input: job.input)
            // Unreachable from the two callers (a leave ended the entry, or the land drains).
            outcome = .failure(CancellationError())
        } catch {
            outcome = .failure(error)
        }
        fillActionSlot(sequence, with: outcome)
        job.task?.cancel()
    }

    /// Test hook: the jobs still running and the slots not yet read.
    package func actionJobCountsForTesting() -> (jobs: Int, slots: Int, started: Int) {
        (actionJobs.count, actionSlots.count, actionJobsStarted)
    }

    /// Test hook: whether the slot of `sequence` holds its outcome, unread.
    package func actionSlotIsFilledForTesting(_ sequence: Int64) -> Bool {
        actionSlots[sequence]?.result != nil
    }

    /// Test hook: the in-flight work count `debugFreeze` waits on.
    package func debugInFlightWorkForTesting() -> Int {
        debugInFlightWork
    }

    /// Test hook: whether the land is frozen.
    /// Test hook, observation only: returns once a freeze is waiting for in-flight work (it
    /// registered its waiter, in the same segment that checked the work).
    package func waitUntilFreezeWaitsForTesting() async {
        guard debugDrainWaiters.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            freezeWaitWatchersForTesting.append(continuation)
        }
    }

    /// Callers of `waitUntilFreezeWaitsForTesting` waiting for a freeze to wait.
    private var freezeWaitWatchersForTesting: [CheckedContinuation<Void, Never>] = []

    package func debugIsFrozenForTesting() -> Bool {
        debugFrozen
    }

    /// Test hook: whether an input drain is scheduled or running (`runInputDrain`).
    package func inputDrainScheduledForTesting() -> Bool {
        inputDrainScheduled
    }

    /// Test hook: whether a caller waits on the slot of `sequence`.
    package func actionResultHasWaiterForTesting(_ sequence: Int64) -> Bool {
        actionSlots[sequence]?.waiter != nil
    }

    /// Test hook, observation only: waits until every job registered so far has left the job
    /// table through the production paths (its completion, or the release once its abandoned
    /// resolvers ended). It never releases a job itself; a job that is never released keeps it
    /// waiting, so callers bound it.
    package func waitForActionJobsForTesting() async {
        for (sequence, job) in actionJobs {
            await job.task?.value
            await job.abandonment.waitUntilEnded()
            // The release is its own turn (`onEnded` hops to the keeper); wait for it without
            // spinning.
            guard actionJobs[sequence] != nil else { continue }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                actionJobRemovalWaiters[sequence, default: []].append(continuation)
            }
        }
    }

    /// Handles a player/client leaving the Land.
    ///
    /// If this is the player's last connection, the `OnLeave` handler is called.
    /// If the Land becomes empty, automatic shutdown may be scheduled.
    ///
    /// If the land starts draining while `OnLeave`'s resolvers run, the `OnLeave` input is
    /// dropped (and logged) and the leave returns normally: its caller isn't told. The player
    /// is removed either way.
    ///
    /// - Parameters:
    ///   - playerID: The player's unique identifier.
    ///   - clientID: The client instance identifier.
    public func leave(playerID: PlayerID, clientID: ClientID) async throws {
        try await leave(playerID: playerID, clientID: clientID, sessionID: nil)
    }

    /// `leave(playerID:clientID:)` for one session: when `sessionID` is given and the player's
    /// entry records a session, the leave applies only to that session. Client IDs are short and
    /// can collide, so a client's leave can't remove another client's entry that shares its ID.
    public func leave(playerID: PlayerID, clientID: ClientID, sessionID: SessionID?) async throws {
        try await ensureInitialized()
        await holds.at(.leave)
        guard let session = players[playerID] else {
            if logger.logLevel <= .debug {
                logger.debug("Leave called for player \(playerID.rawValue) but not found in players dictionary")
            }
            return
        }

        // Verify this is the correct client (should always match since we only allow one client per playerID)
        guard session.clientID == clientID else {
            if logger.logLevel <= .debug {
                logger.debug("Leave called for player \(playerID.rawValue) with mismatched clientID: expected=\(session.clientID?.rawValue ?? "nil"), received=\(clientID.rawValue)")
            }
            return
        }
        if let sessionID, let recorded = session.lastSessionID, recorded != sessionID {
            if logger.logLevel <= .debug {
                logger.debug("Leave called for player \(playerID.rawValue) with mismatched session: expected=\(recorded.rawValue), received=\(sessionID.rawValue)")
            }
            return
        }

        if logger.logLevel <= .debug {
            logger.debug("Player \(playerID.rawValue) leave: clientID=\(clientID.rawValue)")
        }

        // Since we only allow one client per playerID, always call OnLeave handler
        let deviceID = session.deviceID
        let isGuest = session.isGuest
        let metadata = session.metadata
        players.removeValue(forKey: playerID)
        // Its pending actions can't be delivered any more (the ticket names this entry).
        cancelActionJobs(ofEntryGeneration: session.generation)

        // In reevaluation mode, replay viewers never ran OnJoin so skip OnLeave (no game state to clean).
        guard definition.lifetimeHandlers.onLeave != nil, mode != .reevaluation else {
            scheduleDestroyIfNeeded()
            return
        }

        logger.info("Player \(playerID.rawValue) leaving, enqueuing OnLeave lifecycle item")

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
        let sequence = outputCollector.takeNextSequence()

        // Snapshot tick at request time; update after resolver completion for async determinism.
        var resolvedAtTick = lastCommittedTickId
        var resolverOutputs: [String: any ResolverOutput] = [:]

        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onLeaveResolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: session.lastSessionID ?? systemSessionID,
                servicesOverride: session.services,
                deviceID: deviceID,
                isGuest: isGuest,
                metadata: metadata
            )
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: nil,
                eventPayload: nil,
                currentState: state
            )
            do {
                ctx = try await ResolverExecutor.executeResolvers(
                    executors: definition.lifetimeHandlers.onLeaveResolverExecutors,
                    resolverContext: resolverContext,
                    landContext: ctx
                )
            } catch {
                // The player is already removed: its OnLeave is dropped (its sequence is a gap
                // replay steps over), and the player's game state stays behind.
                ResolverDeadline.metrics.noteOnLeaveDropped()
                logger.warning("OnLeave dropped: its resolvers failed", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "error": .string("\(error)"),
                ])
                scheduleDestroyIfNeeded()
                throw error
            }
            resolverOutputs = ctx.getAllResolverOutputs()
            resolvedAtTick = lastCommittedTickId
        }

        // Same synchronous segment as the append: a drain that started during the resolvers
        // has taken the pending inputs and runs the destroy handlers, so this OnLeave is dropped
        // (its sequence is a gap replay steps over). The player was already removed.
        guard !isDraining else {
            logger.warning("OnLeave dropped: the land started closing during its resolvers", metadata: [
                "playerID": .string(playerID.rawValue),
            ])
            return
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: sequence,
                kind: .leave,
                playerID: playerID,
                clientID: clientID,
                sessionID: session.lastSessionID ?? systemSessionID,
                deviceID: deviceID,
                isGuest: isGuest,
                metadata: metadata,
                resolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        )
        pendingItems.append(pendingItem)

        // If there's no tick handler, process lifecycle immediately (backward-compatible mode)
        if definition.lifetimeHandlers.tickHandler == nil {
            if usesInTurnSync {
                _ = try await awaitInputTurn(sequence: sequence)
            } else {
                _ = try await runLegacyPass(for: sequence)
            }
        }

        scheduleDestroyIfNeeded()
    }

    /// Shuts the land down now: the players still in it are cleared without OnLeave, the
    /// inputs not yet applied are dropped, and the destroy runs as for an empty land (#382).
    ///
    /// The clear, the drop and the drain flag are one keeper turn, the shutdown turn, recorded
    /// as the lifecycle event `"shutdown"`; replay stops at it.
    /// - Tickless: the shutdown is an input taken in arrival order. Inputs queued before it are
    ///   applied first (a leave with its OnLeave); inputs after it get `.landClosed`.
    /// - Tick land: no tick starts from the call on. The tick in flight finishes, then the
    ///   shutdown turn runs between ticks, as a frame of its own; the pending inputs would only
    ///   have applied in the next tick, so they are dropped. A join reaching intake after the
    ///   turn gets `.landShuttingDown`.
    ///
    /// A debug freeze is ended first, so held intake re-enters behind the shutdown and is
    /// rejected. Concurrent calls share one shutdown. If the empty-room drain has started (or
    /// starts before the turn), no shutdown turn runs and the call waits for that drain.
    ///
    /// Not to be awaited from inside this land's own tick or input turn (a resolver or handler
    /// waiting for its land's removal): it would wait for that turn.
    public func forceShutdown() async {
        try? await ensureInitialized()
        // A land shuts down once: the flight is never finished, so a later call waits for the
        // same (completed) task.
        let flight = forceShutdownFlight.flight(for: 0) { _ in
            Task { () async throws -> Void in await self.runForceShutdown() }
        }
        inTurnProbeForTesting?("force-shutdown-joined")
        _ = try? await SingleFlight<Int, Void>.value(of: flight)
    }

    /// `forceShutdown`'s one flight.
    private var forceShutdownFlight = SingleFlight<Int, Void>()

    /// Set by a tick land's forced shutdown before it waits for the tick in flight: `runTick`
    /// starts no tick from then on (#382).
    private var shutdownRequested = false

    private func runForceShutdown() async {
        // No turn when the drain has started (the empty-room timer), the initialization failed
        // (#104), or in re-evaluation: as before, the players are cleared and the drain runs or
        // is awaited.
        guard drainTask == nil, !isDraining, initializationFailure == nil, mode == .live else {
            players.removeAll()
            dropPendingInputs(reason: "forceShutdown")
            await shutdownIfIdle(cause: .forceShutdown)
            return
        }
        // One synchronous segment: end a freeze (held intake then re-enters behind the
        // shutdown), then stop new ticks or queue the shutdown input.
        endDebugFreezeForShutdown()
        if definition.lifetimeHandlers.tickHandler != nil {
            shutdownRequested = true
            inTurnProbeForTesting?("shutdown-stop-gate")
            await waitForTickInFlight()
            // If the empty-room drain started during the wait, it is awaited instead.
            if drainTask == nil, !isDraining {
                await applyShutdownTurnBetweenTicks()
            }
        } else {
            let sequence = outputCollector.takeNextSequence()
            pendingItems.append(.shutdown(PendingShutdownItem(sequence: sequence, resolvedAtTick: lastCommittedTickId)))
            inTurnProbeForTesting?("shutdown-queued")
            if usesInTurnSync {
                scheduleInputDrain()
            } else {
                // A pass of its own; its delivery job waits behind earlier passes' deliveries,
                // which the shutdown doesn't wait for. Another caller's pass may apply the
                // shutdown first (every pass applies every ready input); this one then applies
                // nothing. Not `runLegacyPass`: no caller waits on the shutdown's outcome.
                Task {
                    await self.holds.at(.legacyShutdownPass)
                    await self.processPendingActions()
                }
            }
            // Until the turn has applied, or an empty-room drain that started first has dropped
            // the input (that drain is awaited below).
            await withCheckedContinuation { shutdownTurnWaiters.append($0) }
        }
        if shutdownTurnApplied { await holds.at(.shutdownTurnApplied) }
        await shutdownIfIdle(cause: .forceShutdown)
    }

    /// Tests only: what the empty-room timer runs when it fires.
    func runEmptyRoomShutdownForTesting() async {
        await shutdownIfIdle(cause: .emptyTimeout)
    }

    /// Ends a debug freeze for `forceShutdown`, as `debugResume` does, except that the server
    /// inputs accepted during the freeze stay out of the queue: the drain drops them, never
    /// applied, as it would without the shutdown turn. Held intake and `debugFreeze` waiters
    /// resume; the intake re-enters behind the shutdown input and is rejected.
    private func endDebugFreezeForShutdown() {
        guard let generation = debugActiveGeneration else { return }
        debugReleasedGeneration = max(debugReleasedGeneration, generation)
        debugActiveGeneration = nil
        debugFrozen = false
        let held = debugHeldInputs
        debugHeldInputs.removeAll()
        held.forEach { $0.resume() }
        let waiters = debugDrainWaiters
        debugDrainWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    /// A tick land's shutdown turn (#382), between ticks: the stop gate is set and no tick is in
    /// flight. It is a frame of its own, the tick ID the next tick would have taken, holding
    /// only the shutdown. The turn changes no land state, so its state hash is the last tick's.
    private func applyShutdownTurnBetweenTicks() async {
        let tickId = nextTickId
        nextTickId += 1
        let item = PendingItem.shutdown(PendingShutdownItem(
            sequence: outputCollector.takeNextSequence(),
            resolvedAtTick: lastCommittedTickId
        ))
        let applied = applyInputs([item], executingTickId: tickId).applied
        lastCommittedTickId = tickId
        guard reevaluationRecorder != nil else { return }
        var record = makeTurnRecord(tickId: tickId, applied: applied, emitted: [])
        if enableLiveStateHashRecording {
            record.stateHash = liveStateHash(tickId: tickId).hash
        }
        await submitTurnRecord(record)
    }

    // MARK: - Action & Event Handling

    /// Handles an action envelope by decoding and dispatching to the registered handler.
    ///
    /// This is used by transport adapters that receive type-erased `ActionEnvelope` payloads.
    /// In `.live` mode, actions are queued and executed in ticks. In `.reevaluation` mode, returns immediately.
    ///
    /// `submitAction` followed by `awaitActionResult` for an action whose resolvers run in a job.
    public func handleActionEnvelope(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> AnyCodable {
        // An awaiting caller holds its own wait: the action-job caps aren't applied, so direct
        // callers that send concurrently (tests, benchmarks) behave as before.
        switch try await submit(envelope, playerID: playerID, clientID: clientID, sessionID: sessionID, enforcingLimits: false) {
        case .completed(let response):
            return response
        case .pending(let sequence):
            return try await awaitActionResult(sequence: sequence)
        }
    }

    /// Takes an action in: decodes it, runs the intake checks, takes its sequence and ticket.
    ///
    /// On a tick land, an action with resolvers becomes a job: its resolvers run in their own
    /// task, and the call returns `.pending` without waiting for them. The job's completion is a
    /// keeper turn (`completeAction`) that delivers the result like any input, and its outcome
    /// is kept in a slot created here, until `awaitActionResult` reads it.
    ///
    /// Every other action (no resolvers, or a tickless land) is handled through as before and
    /// returns `.completed` with its response.
    ///
    /// A job is subject to the caps (`ActionJobLimits`): over one, the action is rejected at
    /// intake with `ActionLimitRejection`.
    package func submitAction(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> ActionSubmission {
        let submission: ActionSubmission
        do {
            submission = try await submit(envelope, playerID: playerID, clientID: clientID, sessionID: sessionID, enforcingLimits: true)
        } catch {
            await holds.at(.actionSubmitted)
            throw error
        }
        await holds.at(.actionSubmitted)
        return submission
    }

    private func submit(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        enforcingLimits: Bool
    ) async throws -> ActionSubmission {
        try await ensureInitialized()
        // In re-evaluation mode, actions come from ReevaluationSource, not from transport.
        guard mode == .live else {
            // Return empty response in re-evaluation mode.
            return .completed(AnyCodable(()))
        }

        // Tickless lands apply actions immediately: hold them while frozen and count them as
        // in-flight work (resolvers included) so `debugFreeze` drains them. Tick lands only
        // queue the action here; ticks do not run while frozen.
        let isTickless = definition.lifetimeHandlers.tickHandler == nil
        if isTickless {
            try rejectIfLandClosed()
            await debugWaitWhileFrozen()
            debugBeginWork()
        }
        // A tickless job's work ends when its response exists (`fillActionSlot`), not here.
        var endsWorkOnReturn = isTickless
        defer {
            if endsWorkOnReturn { debugEndWork() }
        }

        let decoder = JSONDecoder()
        let typeIdentifier = envelope.typeIdentifier

        guard let handler = definition.actionHandlers.first(where: { handler in
            let actionType = handler.getActionType()
            let actionTypeName = String(describing: actionType)

            // Direct type name match (e.g., "AddGoldAction" == "AddGoldAction")
            if actionTypeName == typeIdentifier {
                return true
            }

            // Match last component (e.g., "Module.AddGoldAction" == "AddGoldAction")
            if actionTypeName.split(separator: ".").last == typeIdentifier.split(separator: ".").last {
                return true
            }

            // Match schema format (camelCase, without "Action" suffix)
            // e.g., "AddGoldAction" -> "AddGold" matches "AddGold"
            let schemaActionID = generateActionIDForMatching(from: actionType)
            if schemaActionID == typeIdentifier {
                return true
            }

            // Also support case-insensitive matching for backward compatibility
            if schemaActionID.lowercased() == typeIdentifier.lowercased() {
                return true
            }

            return false
        }) else {
            throw LandError.actionNotRegistered
        }

        let actionType = handler.getActionType()
        guard let actionPayloadType = actionType as? any ActionPayload.Type else {
            throw LandError.actionNotRegistered
        }

        // Decode action payload from AnyCodable
        let payloadData = try JSONEncoder().encode(envelope.payload)
        let decodedAction = try decoder.decode(actionPayloadType, from: payloadData)

        // Intake segment: the sender check, the sequence and the ticket (the sender's entry
        // generation). After the resolvers' await, only `deliverResolvedAction` runs, which
        // validates the ticket against the current state and appends the input.
        try rejectIfLandClosed()
        try rejectSenderIfSuperseded(playerID: playerID, clientID: clientID, sessionID: sessionID, input: typeIdentifier)
        let becomesJob = !handler.resolverExecutors.isEmpty
        if becomesJob, enforcingLimits {
            try rejectIfOverActionJobLimits(sessionID: sessionID, input: typeIdentifier)
        }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent)
        let sequence = outputCollector.takeNextSequence()
        let ticket = actionTicket(for: playerID, clientID: clientID)

        // Execute resolvers in parallel if any are declared
        var resolverOutputs: [String: any ResolverOutput] = [:]
        if becomesJob {
            // A cancelled caller's action is never delivered, as when its resolvers ran in the
            // caller's task: the job's task wouldn't inherit the cancellation.
            try Task.checkCancellation()
            if isTickless {
                endsWorkOnReturn = false
                ticklessJobWork.insert(sequence)
            }
            startActionJob(
                PendingActionItem(
                    sequence: sequence,
                    action: envelope.payload,
                    actionType: actionPayloadType,
                    playerID: playerID,
                    clientID: clientID,
                    sessionID: sessionID,
                    resolverOutputs: [:],
                    resolvedAtTick: lastCommittedTickId
                ),
                decodedAction: decodedAction,
                executors: handler.resolverExecutors,
                ticket: ticket,
                input: typeIdentifier
            )
            return .pending(sequence: sequence)
        }
        if !handler.resolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                tickId: lastCommittedTickId
            )

            // ActionPayload already conforms to Sendable, so we can use it directly
            let actionPayloadAsSendable = decodedAction as (any Sendable)
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: actionPayloadAsSendable,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await ResolverExecutor.executeResolvers(
                executors: handler.resolverExecutors,
                resolverContext: resolverContext,
                landContext: ctx
            )
            resolverOutputs = ctx.getAllResolverOutputs()
        }

        try deliverResolvedAction(
            PendingActionItem(
                sequence: sequence,
                action: envelope.payload,
                actionType: actionPayloadType,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                resolverOutputs: resolverOutputs,
                // Rebound to the tick current at delivery (`deliverResolvedAction`).
                resolvedAtTick: lastCommittedTickId
            ),
            ticket: ticket,
            input: typeIdentifier
        )

        // If there's no tick handler, process pending actions immediately and return response
        // This maintains backward compatibility for tests and simple use cases
        if definition.lifetimeHandlers.tickHandler == nil {
            if usesInTurnSync {
                // An input turn applies it (with the other ready inputs) and returns its response.
                return .completed(try await awaitInputTurn(sequence: sequence))
            }
            do {
                return .completed(try await runLegacyPass(for: sequence))
            } catch {
                logger.error("Error processing pending actions", metadata: [
                    "error": .string(String(describing: error)),
                ])
                throw error
            }
        }

        // Return immediate ACK (handler will execute in tick)
        // Return empty response - actual response will be available after tick execution
        return .completed(AnyCodable(()))
    }

    /// Generate action ID for matching (same format as schema generation).
    ///
    /// Converts type name to camelCase action ID format (without "Action" suffix).
    /// Example: "AddGoldAction" -> "AddGold"
    private func generateActionIDForMatching(from actionType: Any.Type) -> String {
        let typeName = String(describing: actionType)

        // Remove module prefix if present (e.g., "Module.AddGoldAction" -> "AddGoldAction")
        let baseTypeName: String
        if let lastComponent = typeName.split(separator: ".").last {
            baseTypeName = String(lastComponent)
        } else {
            baseTypeName = typeName
        }

        // Remove "Action" suffix if present, keep camelCase format
        // Example: "AddGoldAction" -> "AddGold"
        var actionID = baseTypeName
        if actionID.hasSuffix("Action") {
            actionID = String(actionID.dropLast(6))
        }

        // Return camelCase format (e.g., "AddGold")
        return actionID
    }

    /// Handles a client event from a player.
    ///
    /// In `.live` mode, a tick land queues the event for its next tick and returns. A tickless
    /// land with in-turn sync applies it in an input turn and returns once that turn applied it,
    /// as `sendAction` does (#55); on the legacy path (in-turn sync off) a task applies it and
    /// this returns at once. In `.reevaluation` mode, returns immediately.
    ///
    /// - Parameters:
    ///   - event: The client event (type-erased).
    ///   - playerID: The player sending the event.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// - Throws: Errors from event validation (e.g., event not registered)
    ///
    /// **Error Handling**:
    /// - On a tickless land with in-turn sync, a handler's error is thrown to the caller, once:
    ///   the event fails alone and is not run again.
    /// - Elsewhere a handler's error is logged where the event is applied (the tick, or the
    ///   legacy pass); this call has already returned.
    /// - The caller (TransportAdapter) sends a thrown error to the client.
    public func handleClientEvent(
        _ event: AnyClientEvent,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws {
        try await ensureInitialized()
        // In re-evaluation mode, events come from ReevaluationSource, not from transport.
        guard mode == .live else {
            return
        }

        // Tickless lands apply events right away (in a task below): hold them while frozen.
        if definition.lifetimeHandlers.tickHandler == nil {
            try rejectIfLandClosed()
            await debugWaitWhileFrozen()
        }

        // Check if event is registered in the client event registry
        guard let descriptor = definition.clientEventRegistry.findDescriptor(for: event.type) else {
            logger.error(
                "Client event type '\(event.type)' is not registered in ClientEvents { Register(...) }",
                metadata: [
                    "eventType": .string(event.type),
                    "landID": .string(definition.id),
                    "playerID": .string(playerID.rawValue),
                ]
            )
            throw LandError.eventNotRegistered
        }

        // Find handlers that can handle this event type
        let matchingHandlers = definition.eventHandlers.filter { handler in
            handler.canHandle(descriptor.type)
        }

        guard !matchingHandlers.isEmpty else {
            logger.error(
                "No handler found for client event type '\(event.type)'",
                metadata: [
                    "eventType": .string(event.type),
                    "landID": .string(definition.id),
                    "playerID": .string(playerID.rawValue),
                ]
            )
            throw LandError.eventNotRegistered
        }

        try rejectIfLandClosed()
        try rejectSenderIfSuperseded(playerID: playerID, clientID: clientID, sessionID: sessionID, input: event.type)

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent)
        let sequence = outputCollector.takeNextSequence()

        // Bind event to lastCommittedTickId for replay logging
        let resolvedAtTick = lastCommittedTickId

        // Create pending item and add to queue
        let pendingItem = PendingItem.clientEvent(
            PendingClientEventItem(
                sequence: sequence,
                event: event,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                resolvedAtTick: resolvedAtTick
            )
        )
        pendingItems.append(pendingItem)

        // A tickless land applies the event now: in an input turn the caller waits for (in-turn
        // sync), or in a legacy pass a task runs. `processPendingActions()` advances the tick
        // counter if needed, so records get valid tick IDs.
        if definition.lifetimeHandlers.tickHandler == nil {
            // Counted as in-flight from now until the event is applied, so `debugFreeze` drains it.
            debugBeginWork()
            if usesInTurnSync {
                // An input turn applies it, and the caller waits for that turn as an action's
                // caller does (#55): it returns once the event is applied, or throws the handler's
                // error. The waiter is registered in this segment, the append's, so a drain
                // started by another input can't apply the event before anyone waits for it.
                // The probe is synchronous: a test learns the event is queued without a
                // suspension between the append and the waiter's registration.
                inTurnProbeForTesting?("client-event-queued")
                defer { debugEndWork() }
                _ = try await awaitInputTurn(sequence: sequence)
                return
            }
            Task { [weak self] in
                guard let self = self else { return }
                // A failing handler is logged by the pass and fails only this event.
                await self.processPendingActions(flushOutputsImmediately: true)
                await self.debugEndWork()
            }
        }

        // A tick land applies the event in its next tick; the legacy path's task applies it soon.
    }

    // MARK: - Server inputs (#387)

    /// Submits a server input: a value the server delivers to the land as a turn input, outside
    /// any client (the result of work a turn requested, for example).
    ///
    /// In one synchronous segment it checks the land can take it, takes the input's sequence from
    /// the counter actions and client events use, and queues it; the keeper applies it in a turn
    /// of its own, in `(resolvedAtTick, sequence)` order with the land's other inputs, with the
    /// system identity, and records it. It returns without waiting for that turn.
    ///
    /// - Returns: `.accepted(sequence:)`, or `.refused(_)` with nothing queued: the keeper isn't
    ///   live, the land declares no `HandleServerInput` for `I`, it is draining or frozen, or it
    ///   already holds `SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND` unapplied server inputs.
    public func submitServerInput<I: ServerInputPayload>(_ input: I) async -> ServerInputOutcome {
        await submitServerInputErased(input)
    }

    private func submitServerInputErased(_ input: any ServerInputPayload) async -> ServerInputOutcome {
        do {
            try await ensureInitialized()
        } catch {
            return .refused(.draining)
        }
        // From here to the append, one synchronous segment.
        guard mode == .live else { return .refused(.notLive) }
        let typeIdentifier = String(describing: type(of: input))
        // Declared by identity, not by name alone: a same-named type from another module or
        // scope isn't the declared one.
        guard let handlers = definition.serverInputHandlers[typeIdentifier],
              handlers.contains(where: { ObjectIdentifier($0.inputType) == ObjectIdentifier(type(of: input)) })
        else { return .refused(.unknownType) }
        guard !isDraining else { return .refused(.draining) }
        // Live applies the form the record holds, so replay applies the same value (#387).
        let payload: AnyCodable
        do {
            payload = try ServerInputCodec.recordedForm(of: input)
        } catch {
            logger.error("Server input refused: its payload has no record form", metadata: [
                "landID": .string(actualLandID ?? definition.id),
                "inputType": .string(typeIdentifier),
                "error": .string("\(error)"),
            ])
            return .refused(.unencodable)
        }
        if serverInputMaxInFlight > 0, serverInputsInFlight >= serverInputMaxInFlight {
            serverInputCapRejections += 1
            logger.debug("Server input refused: the land's in-flight limit is reached", metadata: [
                "landID": .string(actualLandID ?? definition.id),
                "inputType": .string(typeIdentifier),
                "limit": .stringConvertible(serverInputMaxInFlight),
            ])
            return .refused(.overCap)
        }

        let sequence = outputCollector.takeNextSequence()
        let item = PendingItem.serverInput(PendingServerInputItem(
            sequence: sequence,
            typeIdentifier: typeIdentifier,
            payload: payload,
            resolvedAtTick: lastCommittedTickId
        ))
        serverInputsInFlight += 1
        // A debug freeze doesn't refuse: the input keeps its sequence and waits outside the
        // queue until the resume. In the queue, a drain or pass already running would apply it
        // (they apply every ready input and don't stop for a freeze).
        if debugFrozen {
            serverInputsHeldWhileFrozen.append(item)
            return .accepted(sequence: sequence)
        }
        pendingItems.append(item)
        kickServerInputTurn(upTo: sequence)
        return .accepted(sequence: sequence)
    }

    /// Server inputs accepted during a debug freeze, in submission order: queued at the resume
    /// (`releaseServerInputsHeldWhileFrozen`), dropped if the land drains first.
    private var serverInputsHeldWhileFrozen: [PendingItem] = []

    /// A tickless land applies server inputs in an input turn, as it does client events: a task,
    /// counted as in-flight work from now (`debugFreeze` drains it), that waits for the turn
    /// applying `sequence` (in-turn sync) or runs a pass (legacy). A tick land's next tick
    /// applies them.
    private func kickServerInputTurn(upTo sequence: Int64) {
        guard definition.lifetimeHandlers.tickHandler == nil else { return }
        let inTurn = usesInTurnSync
        debugBeginWork()
        Task { [weak self] in
            guard let self else { return }
            await self.holds.at(.serverInputKick)
            if inTurn {
                _ = try? await self.awaitInputTurn(sequence: sequence)
            } else {
                await self.processPendingActions(flushOutputsImmediately: true)
            }
            await self.debugEndWork()
        }
    }

    /// At the resume: queues the server inputs accepted during the freeze and starts their turn.
    private func releaseServerInputsHeldWhileFrozen() {
        guard !serverInputsHeldWhileFrozen.isEmpty else { return }
        let held = serverInputsHeldWhileFrozen
        serverInputsHeldWhileFrozen.removeAll()
        pendingItems.append(contentsOf: held)
        if let last = held.last { kickServerInputTurn(upTo: last.sequence) }
    }

    /// When the land drains: the server inputs held during a freeze are never applied.
    private func dropServerInputsHeldWhileFrozen() {
        guard !serverInputsHeldWhileFrozen.isEmpty else { return }
        serverInputsInFlight -= serverInputsHeldWhileFrozen.count
        logger.info("Server inputs dropped: the land is closing during a debug freeze", metadata: [
            "dropped": .stringConvertible(serverInputsHeldWhileFrozen.count),
        ])
        serverInputsHeldWhileFrozen.removeAll()
    }

    /// Tests only: overrides `SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND` for this keeper.
    package func setServerInputMaxInFlightForTesting(_ limit: Int) {
        serverInputMaxInFlight = limit
    }

    /// Tests only: server inputs submitted and not yet applied.
    package func serverInputsInFlightForTesting() -> Int {
        serverInputsInFlight
    }

    /// The submitter handed to handlers in `LandContext.serverInputs`: it holds this keeper
    /// weakly, so a submit after the keeper is gone is refused instead of keeping it alive.
    private nonisolated var serverInputSubmitter: ServerInputSubmitter {
        ServerInputSubmitter { [weak self] input in
            guard let self else { return .refused(.draining) }
            return await self.submitServerInputErased(input)
        }
    }

    // MARK: - Helpers

    private func makeContext(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        servicesOverride: LandServices? = nil,
        deviceID: String? = nil,
        isGuest: Bool? = nil,
        metadata: [String: String] = [:],
        tickId: Int64? = nil,
        resolverOutputs: [String: any ResolverOutput] = [:]
    ) -> LandContext {
        let baseServices = servicesOverride ?? LandServices()
        let playerServices = players[playerID]?.services
        let resolvedServices = services.merging(baseServices).merging(playerServices ?? LandServices())
        let playerSession = players[playerID]
        // Use actual land instance ID if available, otherwise fall back to definition.id (land type)
        let landID = actualLandID ?? definition.id
        let eventRecordingTickId = tickId ?? lastCommittedTickId
        let collector = outputCollector
        return LandContext(
            landID: landID,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            services: resolvedServices,
            logger: logger,
            deviceID: deviceID ?? playerSession?.deviceID,
            isGuest: isGuest ?? playerSession?.isGuest ?? false,
            metadata: metadata.isEmpty ? (playerSession?.metadata ?? [:]) : metadata,
            tickId: tickId,
            emitEventHandler: { anyEvent, target in
                collector.enqueueEmittedEvent(anyEvent, to: target, tickId: eventRecordingTickId)
            },
            requestSyncNowHandler: {
                collector.requestSyncNow(tickId: eventRecordingTickId)
            },
            requestSyncBroadcastOnlyHandler: {
                collector.requestSyncBroadcastOnly(tickId: eventRecordingTickId)
            },
            resolverOutputs: resolverOutputs,
            serverInputs: serverInputSubmitter
        )
    }

    /// Runs a handler on the state, in place: handlers are synchronous, so the body can't
    /// suspend and the actor's state is mutated directly.
    ///
    /// A handler that throws keeps what it wrote before the throw (#87). `throwWriteKey` names
    /// the input (`"action <type>"`, `"OnJoin"`, ...) when that matters: in debug builds a live
    /// land then keeps a copy of the state before the handler and, if the handler throws,
    /// compares the synced state with it and warns once per key when the handler wrote
    /// (`warnIfThrowWrote`). `nil` skips the check (replay, or a handler whose state nothing
    /// reads afterwards). Release builds never copy, and never build the key.
    private func withMutableStateSync<R>(
        throwWriteKey: @autoclosure () -> String?,
        _ body: (inout State) throws -> R
    ) rethrows -> R {
        #if DEBUG
        if warnsThrowingInputWrites, mode == .live, let throwWriteKey = throwWriteKey(),
           !throwWriteWarnedKeys.contains(throwWriteKey) {
            // Copy-on-write: this retains the state's storage; the handler's first write to a
            // container then copies that container (debug builds only).
            let before = state
            do {
                return try body(&state)
            } catch {
                warnIfThrowWrote(throwWriteKey, before: before, error: error)
                throw error
            }
        }
        #endif
        return try body(&state)
    }

    #if DEBUG
    /// Keys that already warned (`withMutableStateSync`): each warns once per keeper, and is
    /// not checked again.
    private var throwWriteWarnedKeys: Set<String> = []

    /// Warns when a handler that threw changed the synced state (`fullStateSnapshot`, which
    /// leaves out `@Internal` fields) before the throw.
    private func warnIfThrowWrote(_ key: String, before: State, error: any Error) {
        let changed: Bool
        do {
            changed = try before.fullStateSnapshot() != state.fullStateSnapshot()
        } catch {
            logger.debug("Throwing-input write check skipped: the state snapshot failed", metadata: [
                "input": .string(key),
                "error": .string(String(describing: error)),
            ])
            return
        }
        guard changed else { return }
        throwWriteWarnedKeys.insert(key)
        logger.warning(
            "A handler threw after writing state; its writes are kept and synced. Validate before you mutate (#87). Logged once per input type in debug builds.",
            metadata: [
                "landID": .string(actualLandID ?? definition.id),
                "input": .string(key),
                "error": .string(String(describing: error)),
            ]
        )
    }
    #endif

    /// Whether debug builds check a throwing handler for writes (`withMutableStateSync`):
    /// `EnvKeys.Debug.warnThrowingInputWrites`, default on. Ignored in release builds.
    private var warnsThrowingInputWrites = ThrowingInputWriteCheck.isEnabled()

    /// Tests only: turns the throwing-input write check on or off for this keeper.
    func setWarnsThrowingInputWritesForTesting(_ enabled: Bool) {
        warnsThrowingInputWrites = enabled
    }

    // MARK: - Tick & Lifetime

    /// Ensure tick ID is advanced for tickless lands (no tick handler)
    /// This prevents all records from ending up with tickId = -1
    private func ensureTickIdForTicklessLand() {
        // Advance tick counter to ensure records use a valid tick ID
        // Use max(lastCommittedTickId+1, 0) to ensure non-negative tick IDs
        if nextTickId <= lastCommittedTickId {
            nextTickId = max(lastCommittedTickId + 1, 0)
        }
    }

    /// Offsets the tick and sync loops captured when they were configured (nil: not started).
    private(set) var appliedTickPhaseOffset: Duration?

    /// When the tick loop was last configured: the reference its phase offset and first
    /// interval are measured from (tests).
    private(set) var tickLoopConfiguredAt: ContinuousClock.Instant?
    private(set) var appliedSyncPhaseOffset: Duration?

    /// Delay before the first iteration of a loop with `interval`: `LandLoopPhase.offset` of
    /// this land's instance ID, or `.zero` when disabled. A keeper created without `landID:`
    /// falls back to the land type until `setLandID(_:)`.
    func loopPhaseOffset(interval: Duration) -> Duration {
        guard enableLoopPhaseOffset else { return .zero }
        return LandLoopPhase.offset(landID: actualLandID ?? definition.id, interval: interval)
    }

    /// The clock the tick loop reads and sleeps on: `TickLoopClock.forNewKeepers` when this
    /// keeper was created (the continuous clock, unless a test bound a manual one).
    private let tickLoopClock = TickLoopClock.forNewKeepers

    private func configureTickLoop(interval: Duration) async {
        tickTask?.cancel()
        let phaseOffset = loopPhaseOffset(interval: interval)
        let clock = tickLoopClock
        appliedTickPhaseOffset = phaseOffset
        tickLoopConfiguredAt = clock.now()
        tickTask = Task { [weak self] in
            if phaseOffset > .zero {
                await clock.sleepFor(phaseOffset)
            }
            guard let self = self else { return }

            var nextTickTime = clock.now() + interval
            await self.noteNextTickDeadline(nextTickTime)

            while !Task.isCancelled {
                // If we're already past the scheduled time, execute immediately
                // Otherwise, sleep until the scheduled time
                if clock.now() < nextTickTime {
                    await clock.sleepUntil(nextTickTime)
                }

                await self.runTick(allowWhenNoTickTask: false)

                // Fixed-rate scheduling: calculate next time from the scheduled time, not from now
                // This maintains a consistent tick rate even if execution takes longer than interval
                // If execution time exceeds interval, we skip ahead to maintain the rate
                nextTickTime = nextTickTime + interval

                // If we're still behind schedule after skipping, continue skipping
                // This prevents the loop from getting stuck if execution time consistently exceeds interval
                while nextTickTime <= clock.now() {
                    nextTickTime = nextTickTime + interval
                }
                await self.noteNextTickDeadline(nextTickTime)
            }
        }
    }

    private func noteNextTickDeadline(_ deadline: ContinuousClock.Instant) {
        nextTickDeadline = deadline
    }

    /// Manually execute a single tick (for deterministic tests/tools).
    ///
    /// This bypasses the internal tick loop guard and allows stepping a land deterministically
    /// without relying on wall-clock time.
    ///
    /// With in-turn sync (`InTurnSync`) this is one tick turn: ready inputs, the tick handler,
    /// the emitted events and, only when a sync is due (coincident-sync rule) or a handler
    /// requested one, the sync phase. The phase can be deferred by writer back-pressure, and
    /// returning does not mean the writer has sent the frames. On a tickless land it runs the
    /// ready inputs as input turns; when an input drain is already scheduled but has not run
    /// yet, it can return before those inputs are applied (the drain applies them).
    public func stepTickOnce() async {
        guard (try? await ensureInitialized()) != nil else { return }
        await runTick(allowWhenNoTickTask: true)
    }

    /// What applying pending items produced, for recording and output.
    private struct AppliedInputs {
        let executingTickId: Int64
        var recordedActions: [ReevaluationRecordedAction] = []
        var recordedClientEvents: [ReevaluationRecordedClientEvent] = []
        var recordedLifecycleEvents: [ReevaluationRecordedLifecycleEvent] = []
        var recordedServerInputs: [ReevaluationRecordedServerInput] = []
        /// The recorded inputs' sequences in apply order, across the four lists (a tickless
        /// land's pass, `ReevaluationRecordedPass`).
        var appliedOrder: [Int64] = []
        /// A leave ran: the legacy path follows with a broadcast-only sync.
        var shouldSyncBroadcastOnly = false

        init(executingTickId: Int64) {
            self.executingTickId = executingTickId
        }

        var isEmpty: Bool {
            recordedActions.isEmpty && recordedClientEvents.isEmpty && recordedLifecycleEvents.isEmpty
                && recordedServerInputs.isEmpty
        }
    }

    private enum AppliedItem {
        case action(response: AnyCodable)
        case other
        case skipped
    }

    /// The tick a tickless drain (or a pending-items pass) records under: `nextTickId - 1`,
    /// advancing `nextTickId` first when no tick has been taken yet, so records never use -1.
    private func executingTickIdForPendingItems() -> Int64 {
        var executingTickId = nextTickId - 1
        if executingTickId < 0 {
            nextTickId = max(lastCommittedTickId + 1, 0)
            executingTickId = nextTickId - 1
            // If still negative (lastCommittedTickId was -1), use 0
            if executingTickId < 0 {
                nextTickId = 1
                executingTickId = 0
            }
        }
        return executingTickId
    }

    /// The pending items ready to execute (`resolvedAtTick < nextTickId`), in execution order:
    /// by `resolvedAtTick`, then by sequence.
    private func readyPendingItemsInOrder() -> [PendingItem] {
        pendingItems
            .filter { $0.resolvedAtTick < nextTickId }
            .sorted { lhs, rhs in
                if lhs.resolvedAtTick != rhs.resolvedAtTick {
                    return lhs.resolvedAtTick < rhs.resolvedAtTick
                }
                return lhs.sequence < rhs.sequence
            }
    }

    /// Removes `items` from the pending queue (by sequence).
    private func removePendingItems(_ items: [PendingItem]) {
        guard !items.isEmpty else { return }
        let executedSequences = Set(items.map(\.sequence))
        pendingItemScans += pendingItems.count
        pendingItems.removeAll { executedSequences.contains($0.sequence) }
    }

    /// Queue elements visited by whole-queue scans (removals, replay's frame reads): the work a
    /// frame's replay does on the queue, for a bound on it in tests.
    private var pendingItemScans = 0

    /// Tests only: `pendingItemScans` so far.
    func pendingItemScansForTesting() -> Int {
        pendingItemScans
    }

    /// Tests only: removes the queued input with `sequence` (a queue changed across an await).
    func removePendingItemForTesting(sequence: Int64) {
        pendingItems.removeAll { $0.sequence == sequence }
    }

    /// Applies one pending item to the state (synchronous) and appends its record to `applied`.
    /// The record is appended before the handler runs, so an item whose handler throws is
    /// recorded too (replay fails it the same way); the error propagates to `applyInputs`.
    private func applyPendingItem(
        _ item: PendingItem,
        executingTickId: Int64,
        into applied: inout AppliedInputs
    ) throws -> AppliedItem {
        // A server input leaves the in-flight count once it is taken out to apply, whatever the
        // outcome (replay's items were never counted).
        if case .serverInput = item, serverInputsInFlight > 0 {
            serverInputsInFlight -= 1
        }
        // Every append path checks `isDraining`; this guard keeps the guarantee if one doesn't.
        guard !destroyHandlersStarted else {
            inputsSkippedAfterDestroy += 1
            logger.error("Input skipped: the land's destroy handlers have started", metadata: [
                "sequence": .stringConvertible(item.sequence),
            ])
            return .skipped
        }
        switch item {
        case let .action(actionItem):
            // Find handler for this action type
            guard let handler = definition.actionHandlers.first(where: { handler in
                handler.canHandle(actionItem.actionType)
            }) else {
                logger.error("Handler not found for action type", metadata: [
                    "actionType": .string(String(describing: actionItem.actionType)),
                ])
                return .skipped
            }

            // Decode action from AnyCodable
            let decoder = JSONDecoder()
            let payloadData = try JSONEncoder().encode(actionItem.action)
            let decodedAction = try decoder.decode(actionItem.actionType, from: payloadData)

            // Create context with resolver outputs
            let ctx = makeContext(
                playerID: actionItem.playerID,
                clientID: actionItem.clientID,
                sessionID: actionItem.sessionID,
                tickId: executingTickId,
                resolverOutputs: actionItem.resolverOutputs
            )

            // Recorded before the handler runs: an input whose handler throws is recorded too, so
            // replay runs it again and it fails the same way (`applyInputs`).
            let resolverOutputsDict = actionItem.resolverOutputs.mapValues { output in
                ReevaluationRecordedResolverOutput(
                    typeIdentifier: String(describing: type(of: output)),
                    value: AnyCodable(output)
                )
            }
            let recordedAction = ReevaluationRecordedAction(
                kind: "action",
                sequence: actionItem.sequence,
                typeIdentifier: String(describing: actionItem.actionType),
                payload: actionItem.action,
                playerID: actionItem.playerID.rawValue,
                clientID: actionItem.clientID.rawValue,
                sessionID: actionItem.sessionID.rawValue,
                resolverOutputs: resolverOutputsDict,
                resolvedAtTick: actionItem.resolvedAtTick
            )
            applied.recordedActions.append(recordedAction)
            applied.appliedOrder.append(recordedAction.sequence)

            // Execute handler and capture response
            let response = try withMutableStateSync(throwWriteKey: "action \(String(describing: actionItem.actionType))") { state in
                try handler.invokeErased(&state, action: decodedAction, ctx: ctx)
            }
            return .action(response: response)



        case let .clientEvent(eventItem):
            // Find handlers for this event type
            guard let descriptor = definition.clientEventRegistry.findDescriptor(for: eventItem.event.type) else {
                logger.error("Event descriptor not found", metadata: [
                    "eventType": .string(eventItem.event.type),
                ])
                return .skipped
            }

            let matchingHandlers = definition.eventHandlers.filter { handler in
                handler.canHandle(descriptor.type)
            }

            guard !matchingHandlers.isEmpty else {
                logger.error("No handler found for client event", metadata: [
                    "eventType": .string(eventItem.event.type),
                ])
                return .skipped
            }

            // Create context (client events don't have resolver outputs)
            let ctx = makeContext(
                playerID: eventItem.playerID,
                clientID: eventItem.clientID,
                sessionID: eventItem.sessionID,
                tickId: executingTickId,
                resolverOutputs: [:]
            )

            // Recorded before the handlers run (see the action case).
            let recordedClientEvent = ReevaluationRecordedClientEvent(
                kind: "clientEvent",
                sequence: eventItem.sequence,
                typeIdentifier: eventItem.event.type,
                payload: eventItem.event.payload,
                playerID: eventItem.playerID.rawValue,
                clientID: eventItem.clientID.rawValue,
                sessionID: eventItem.sessionID.rawValue,
                resolvedAtTick: eventItem.resolvedAtTick
            )
            applied.recordedClientEvents.append(recordedClientEvent)
            applied.appliedOrder.append(recordedClientEvent.sequence)

            // Execute handlers
            try withMutableStateSync(throwWriteKey: "event \(eventItem.event.type)") { state in
                for handler in matchingHandlers {
                    try handler.invoke(&state, event: eventItem.event, ctx: ctx)
                }
            }

        case let .serverInput(inputItem):
            guard let handlers = definition.serverInputHandlers[inputItem.typeIdentifier] else {
                // Only replay gets here: live refuses an undeclared type at submit.
                logger.warning("Server input skipped: the land declares no handler for its type", metadata: [
                    "inputType": .string(inputItem.typeIdentifier),
                    "sequence": .stringConvertible(inputItem.sequence),
                ])
                return .skipped
            }
            let ctx = makeContext(
                playerID: LandContext.systemPlayerID,
                clientID: LandContext.systemClientID,
                sessionID: LandContext.systemSessionID,
                tickId: executingTickId
            )
            // Recorded before the handlers run (see the action case).
            let recorded = ReevaluationRecordedServerInput(
                sequence: inputItem.sequence,
                typeIdentifier: inputItem.typeIdentifier,
                payload: inputItem.payload,
                resolvedAtTick: inputItem.resolvedAtTick
            )
            applied.recordedServerInputs.append(recorded)
            applied.appliedOrder.append(recorded.sequence)
            try withMutableStateSync(throwWriteKey: "serverInput \(inputItem.typeIdentifier)") { state in
                for handler in handlers {
                    try handler.invoke(&state, payload: inputItem.payload, ctx: ctx)
                }
            }

        case let .shutdown(shutdownItem):
            // Recorded like any input. No handler runs: a forced shutdown runs no OnLeave (#382).
            let recorded = ReevaluationRecordedLifecycleEvent(
                kind: Self.shutdownLifecycleKind,
                sequence: shutdownItem.sequence,
                tickId: executingTickId,
                playerID: nil,
                clientID: nil,
                sessionID: nil,
                deviceID: nil,
                isGuest: nil,
                metadata: [:],
                resolverOutputs: [:],
                resolvedAtTick: shutdownItem.resolvedAtTick
            )
            applied.recordedLifecycleEvents.append(recorded)
            applied.appliedOrder.append(recorded.sequence)
            // In re-evaluation `players` holds the replay's viewers: the shutdown only ends the
            // replay (`completeShutdownTurn`).
            if mode == .live { players.removeAll() }

        case let .lifecycle(lifecycleItem):
            // Recorded before the handler runs (see the action case).
            let resolverOutputsDict = lifecycleItem.resolverOutputs.mapValues { output in
                ReevaluationRecordedResolverOutput(
                    typeIdentifier: String(describing: type(of: output)),
                    value: AnyCodable(output)
                )
            }
            let recordedLifecycleEvent = ReevaluationRecordedLifecycleEvent(
                kind: lifecycleItem.kind.rawValue,
                sequence: lifecycleItem.sequence,
                tickId: executingTickId,
                playerID: lifecycleItem.playerID?.rawValue,
                clientID: lifecycleItem.clientID?.rawValue,
                sessionID: lifecycleItem.sessionID?.rawValue,
                deviceID: lifecycleItem.deviceID,
                isGuest: lifecycleItem.isGuest,
                metadata: lifecycleItem.metadata,
                resolverOutputs: resolverOutputsDict,
                resolvedAtTick: lifecycleItem.resolvedAtTick
            )
            applied.recordedLifecycleEvents.append(recordedLifecycleEvent)
            applied.appliedOrder.append(recordedLifecycleEvent.sequence)

            switch lifecycleItem.kind {
            case .initialize:
                guard let handler = definition.lifetimeHandlers.onInitialize,
                      !replayedInitializeBeforeTickZero else { break }
                let ctx = makeContext(
                    playerID: systemPlayerID,
                    clientID: systemClientID,
                    sessionID: systemSessionID,
                    tickId: executingTickId,
                    resolverOutputs: lifecycleItem.resolverOutputs
                )
                // Execute handler synchronously (resolver outputs already injected). Only
                // re-evaluation queues an initialize item, so the check (live only) never runs.
                try withMutableStateSync(throwWriteKey: "OnInitialize") { state in
                    try handler(&state, ctx)
                }
            case .join:
                guard
                    let playerID = lifecycleItem.playerID,
                    let clientID = lifecycleItem.clientID,
                    let sessionID = lifecycleItem.sessionID,
                    let handler = definition.lifetimeHandlers.onJoin
                else { break }
                let ctx = makeContext(
                    playerID: playerID,
                    clientID: clientID,
                    sessionID: sessionID,
                    deviceID: lifecycleItem.deviceID,
                    isGuest: lifecycleItem.isGuest,
                    metadata: lifecycleItem.metadata,
                    tickId: executingTickId,
                    resolverOutputs: lifecycleItem.resolverOutputs
                )
                // A discarded join's writes stay and reach the other players: checked.
                try withMutableStateSync(throwWriteKey: "OnJoin") { state in
                    try handler(&state, ctx)
                }
            case .leave:
                guard
                    let playerID = lifecycleItem.playerID,
                    let clientID = lifecycleItem.clientID,
                    let sessionID = lifecycleItem.sessionID,
                    let handler = definition.lifetimeHandlers.onLeave
                else { break }
                let ctx = makeContext(
                    playerID: playerID,
                    clientID: clientID,
                    sessionID: sessionID,
                    deviceID: lifecycleItem.deviceID,
                    isGuest: lifecycleItem.isGuest,
                    metadata: lifecycleItem.metadata,
                    tickId: executingTickId,
                    resolverOutputs: lifecycleItem.resolverOutputs
                )
                // The player is gone whether OnLeave succeeds or throws: the broadcast-only sync
                // follows the pass either way. Deferred until after the pending items' removal.
                applied.shouldSyncBroadcastOnly = true
                try withMutableStateSync(throwWriteKey: "OnLeave") { state in
                    try handler(&state, ctx)
                }
            }
        }
        return .other
    }

    /// Applies the pending inputs that are ready (the legacy path: in-turn sync off, or a tick
    /// land's tick), in order (`applyInputs`), then records them, runs the broadcast-only sync a
    /// leave asks for, and flushes the outputs.
    ///
    /// An input whose handler throws fails alone and the pass goes on (`applyInputs`). Each
    /// input's outcome is kept by sequence for the off-path caller waiting for it
    /// (`runLegacyPass`), not returned: one pass can apply several callers' inputs (#88).
    /// - Parameter flushOutputsImmediately: If true, flush outputs after processing. If false, defer flushing (caller should flush after tick handler).
    private func processPendingActions(flushOutputsImmediately: Bool = true) async {
        let owner = legacyPassOwner
        legacyPassOwner = nil
        let executingTickId = executingTickIdForPendingItems()
        let sequenceBefore = outputCollector.nextSequence
        let application = applyInputs(readyPendingItemsInOrder(), executingTickId: executingTickId)
        let applied = application.applied
        for (sequence, outcome) in application.outcomes where legacyPassCallers.contains(sequence) {
            legacyPassResults[sequence] = outcome
            if let owner { legacyPassAppliedBy[sequence] = owner }
        }
        if flushOutputsImmediately, mode == .live, definition.lifetimeHandlers.tickHandler == nil {
            // Taken in the apply segment: the pass that applies a tickless job answers it, after
            // its record (whichever pass that is: any caller's pass applies every ready input).
            let jobOutcomes = application.outcomes.filter { ticklessJobTurns.remove($0.key) != nil }
            await finishTicklessLegacyPass(
                applied: applied,
                sequenceBefore: sequenceBefore,
                executingTickId: executingTickId
            )
            for (sequence, outcome) in jobOutcomes {
                fillActionSlot(sequence, with: outcome)
            }
            return
        }
        await holds.at(.turnRecord)
        let recordedActions = applied.recordedActions
        let recordedClientEvents = applied.recordedClientEvents
        let recordedLifecycleEvents = applied.recordedLifecycleEvents
        let recordedServerInputs = applied.recordedServerInputs
        let shouldSyncBroadcastOnly = applied.shouldSyncBroadcastOnly

        // Record inputs to ReevaluationRecorder
        if let recorder = reevaluationRecorder,
           !recordedActions.isEmpty || !recordedClientEvents.isEmpty || !recordedLifecycleEvents.isEmpty
            || !recordedServerInputs.isEmpty
        {
            // Use the tick ID that was used for processing (nextTickId - 1, since we incremented it before processing)
            let recordingTickId = nextTickId - 1
            await recorder.record(
                tickId: recordingTickId,
                actions: recordedActions,
                clientEvents: recordedClientEvents,
                lifecycleEvents: recordedLifecycleEvents,
                serverInputs: recordedServerInputs
            )

            // Flush if needed
            try? await recorder.flushIfNeeded(currentTick: recordingTickId)
        }

        if shouldSyncBroadcastOnly {
            await transport?.syncBroadcastOnlyFromTransport()
        }

        // Flush deterministic outputs produced while processing pending items.
        // Only flush immediately if requested (e.g., for tickless lands).
        // In normal tick flow, flush is deferred until after tick handler to ensure
        // outputs include state changes from the tick handler.
        if flushOutputsImmediately {
            // A live tickless pass ends in `finishTicklessLegacyPass` (its turn record, #327);
            // here the keeper is re-evaluating, with no recorder.
            await flushOutputs(forTick: executingTickId)
        }
    }

    /// The end of a live tickless legacy pass (#325): its inputs, its pass and its server events
    /// are taken and submitted in the segment that applied them, as one turn record through the
    /// ordered submission queue, so the record holds passes in apply order and one record per
    /// pass however passes interleave at the awaits below.
    ///
    /// Its delivery is enqueued in the same segment, as one job on `legacyDeliveries`, so passes
    /// deliver in apply order (as one flush of the tick's events in sequence order did before):
    /// the job waits for this pass's record, then runs the broadcast-only sync, then sends this
    /// pass's events. Nothing in a job may enqueue onto, or await, `legacyDeliveries`: the
    /// broadcast-only sync plans from a snapshot and applies no input, so it can't start a pass.
    /// The sync requests (`syncNow`, which can reach input application) run in this frame after
    /// the job, outside the queue. `.turnRecord` holds this frame after both are enqueued; the
    /// job doesn't wait for it. `.legacyDelivery` holds the job at its start.
    private func finishTicklessLegacyPass(
        applied: AppliedInputs,
        sequenceBefore: Int64,
        executingTickId: Int64
    ) async {
        // All tickless passes share one tick id, so the events and sync requests are taken
        // here: a later pass can't flush this pass's, nor this pass a later one's.
        let events = takeEmittedEvents(forTick: executingTickId)
        let syncRequests = outputCollector.syncRequestsByTick.removeValue(forKey: executingTickId)
        // The pass is one turn record (#327): its inputs, pass and events in one submission that
        // ends the turn. With nothing of its own to record it still ends the turn, closing what
        // reached the recorder during the pass (as before #325).
        var submission: Task<Void, Never>?
        if let recorder = reevaluationRecorder {
            if !applied.isEmpty || !events.isEmpty {
                var record = makeTurnRecord(tickId: executingTickId, applied: applied, emitted: events)
                if !applied.appliedOrder.isEmpty {
                    record.passes = [ReevaluationRecordedPass(sequenceBefore: sequenceBefore, inputs: applied.appliedOrder)]
                }
                submission = enqueueRecorderSubmission(record, endsTurn: true)
            } else {
                recorderSubmissionCount += 1
                submission = recorderSubmissions.submit { await recorder.endTurn() }
            }
        }
        let broadcastOnly = applied.shouldSyncBroadcastOnly
        let recordSubmission = submission
        let delivery = legacyDeliveries.submit { [weak self] in
            await self?.deliverLegacyPass(after: recordSubmission, broadcastOnly: broadcastOnly, events: events)
        }
        await holds.at(.turnRecord)
        await delivery.value
        await runSyncRequests(syncRequests)
    }

    /// A legacy pass's delivery job (`finishTicklessLegacyPass`): runs on `legacyDeliveries`,
    /// after every earlier pass's job.
    private func deliverLegacyPass(after submission: Task<Void, Never>?, broadcastOnly: Bool, events: [EmittedEvent]) async {
        await holds.at(.legacyDelivery)
        await submission?.value
        if broadcastOnly {
            await transport?.syncBroadcastOnlyFromTransport()
        }
        for item in events {
            await transport?.sendEventToTransport(item.event, to: item.target)
        }
    }

    /// Off-path tickless inputs whose caller waits in `runLegacyPass`, by sequence.
    private var legacyPassCallers: Set<Int64> = []
    /// The outcome of each such input, set by the pass that applied it.
    private var legacyPassResults: [Int64: Result<AnyCodable, any Error>] = [:]
    /// The caller whose pass starts next (`runLegacyPass`), and, per caller's input, the caller
    /// whose pass applied it: the check that a caller's input is applied by its own pass.
    private var legacyPassOwner: Int64?
    private var legacyPassAppliedBy: [Int64: Int64] = [:]

    /// Off path (in-turn sync off), tickless: runs a pending-items pass for the input with
    /// `sequence`, appended in this segment, and returns that input's own outcome (#88): its
    /// action's response, an empty one for a join or leave, or its handler's error.
    ///
    /// The pass applies the input synchronously (a tickless input is always ready), so its
    /// outcome is set before the pass's first `await`.
    private func runLegacyPass(for sequence: Int64) async throws -> AnyCodable {
        legacyPassCallers.insert(sequence)
        defer {
            legacyPassCallers.remove(sequence)
            legacyPassResults.removeValue(forKey: sequence)
            legacyPassAppliedBy.removeValue(forKey: sequence)
        }
        // Rule: a caller's input is applied by its own pass, so the caller returns only after
        // that pass's record (a response never leaves before its input is recorded). It holds
        // while the pass applies before its first await; an await before the apply breaks it.
        legacyPassOwner = sequence
        await processPendingActions()
        assert(legacyPassAppliedBy[sequence] == sequence, "Input \(sequence) was applied by another legacy pass, before its own")
        guard let outcome = legacyPassResults[sequence] else {
            assertionFailure("The pass did not apply the input it ran for (sequence \(sequence))")
            return AnyCodable(())
        }
        return try outcome.get()
    }

    /// What `applyInputs` did: the records (failed inputs included) and each input's outcome.
    private struct InputApplication {
        var applied: AppliedInputs
        /// Every input's outcome, by sequence: its response (empty for non-actions) or its error.
        var outcomes: [Int64: Result<AnyCodable, any Error>]
        var failureCount: Int
    }

    /// Applies `items` in order (synchronous), on every path (legacy pass, in-turn input turn,
    /// in-turn tick turn), and removes them all from the queue in the same segment.
    ///
    /// An input P whose handler throws fails alone: its outcome is its error (its caller gets
    /// it), the events it emitted are dropped, a failed join is discarded
    /// (`discardIfFailedJoin`), and the inputs after it continue in the same pass with their own
    /// outcomes. P is not run again and blocks nothing. P is recorded like the others, in order
    /// (`applyPendingItem` records before the handler runs), so replay runs it again and it
    /// fails the same way. What P wrote to the state before it threw stays and goes out with the
    /// next sync like any other change (undoing it needs a per-input savepoint, #87). A throwing
    /// OnLeave is such a case: the keeper has already removed the player and the broadcast-only
    /// sync still runs, but whatever OnLeave would have cleaned up after the throw (say, the
    /// player's entry in the state) stays in the state and is broadcast as it is.
    private func applyInputs(_ items: [PendingItem], executingTickId: Int64, removingFromQueue: Bool = true) -> InputApplication {
        var applied = AppliedInputs(executingTickId: executingTickId)
        var outcomes: [Int64: Result<AnyCodable, any Error>] = [:]
        var failureCount = 0
        var joinResults: [JoinInputResult] = []
        // The shutdown is the last input a land applies (#382): the batch ends at it.
        var consumed = items.count
        var appliedShutdown = false
        for (index, item) in items.enumerated() {
            let sequenceBefore = outputCollector.nextSequence
            let isJoin: Bool
            if case let .lifecycle(lifecycle) = item, lifecycle.kind == .join { isJoin = true } else { isJoin = false }
            do {
                switch try applyPendingItem(item, executingTickId: executingTickId, into: &applied) {
                case .action(let response): outcomes[item.sequence] = .success(response)
                case .other, .skipped: outcomes[item.sequence] = .success(AnyCodable(()))
                }
                if isJoin { joinResults.append(JoinInputResult(sequence: item.sequence, failed: false)) }
            } catch {
                if isJoin { joinResults.append(JoinInputResult(sequence: item.sequence, failed: true)) }
                failureCount += 1
                outcomes[item.sequence] = .failure(error)
                outputCollector.emittedEvents.removeAll { $0.sequence >= sequenceBefore }
                discardIfFailedJoin(item)
                logger.error("Input failed: its handler threw; the inputs after it continue", metadata: [
                    "sequence": .stringConvertible(item.sequence),
                    "error": .string(String(describing: error)),
                ])
            }
            if item.isShutdown {
                consumed = index + 1
                appliedShutdown = true
                break
            }
        }
        if removingFromQueue { removePendingItems(Array(items.prefix(consumed))) }
        noteJoinInputsConsumed(joinResults)
        if appliedShutdown { completeShutdownTurn() }
        return InputApplication(applied: applied, outcomes: outcomes, failureCount: failureCount)
    }

    /// Re-evaluation only: replays a tickless frame's inputs pass by pass, in recorded order,
    /// each pass as an input turn (`runInputTurn`, the live drain's turn) with its inputs in
    /// listed order, right after restoring the pass's sequence watermark (#325, #321). Returns
    /// whether a leave asks for a broadcast-only sync.
    ///
    /// Linear in the frame's inputs (a tickless frame holds the whole session): they are indexed
    /// by sequence once, each pass takes its batch from the index, and the turns leave the queue
    /// alone; the frame's inputs are removed from it once, at the end.
    ///
    /// Holds at `.inputDrain` first and submits each turn's record (`.turnRecord`), as the live
    /// drain does; without a hook or a recorder neither suspends. The passes are checked against
    /// every input loaded for the frame before any turn runs: each loaded input must be ready,
    /// carry its own sequence, and be named by exactly one pass; no pass may name anything else;
    /// watermarks must not decrease. OnInitialize's lifecycle input is outside them: it was
    /// replayed before tick 0, and is applied (as a no-op) first. If the queue changed across
    /// the awaits between passes, the index is rebuilt from it, so a pass never applies an input
    /// that is no longer queued. When the passes don't match, no further input of the frame is
    /// applied (they are dropped from the queue) and the mismatch is kept for the engine and the
    /// hosted runner (`takeRecordedPassMismatch(for:)`), which fail the tick: a record whose
    /// order can't be trusted is never replayed in some other order.
    private func replayRecordedPasses(_ passes: [ReevaluationRecordedPass], tickId: Int64) async -> Bool {
        await holds.at(.inputDrain)
        let isInitialize: (PendingItem) -> Bool = { item in
            if case let .lifecycle(lifecycle) = item, lifecycle.kind == .initialize { return true }
            return false
        }
        let initializeItems = readyPendingItemsInOrder().filter(isInitialize)
        pendingItemScans += pendingItems.count
        let inputs = pendingItems.filter { !isInitialize($0) }.sorted { $0.sequence < $1.sequence }

        var mismatch: String?
        var bySequence: [Int64: PendingItem] = [:]
        for item in inputs where mismatch == nil {
            if bySequence.updateValue(item, forKey: item.sequence) != nil {
                mismatch = "the tick holds more than one input with sequence \(item.sequence)"
            } else if item.resolvedAtTick >= nextTickId {
                mismatch = "the input with sequence \(item.sequence) resolves at tick \(item.resolvedAtTick), after the tick"
            }
        }
        var named: Set<Int64> = []
        var previousWatermark = Int64.min
        for (index, pass) in passes.enumerated() where mismatch == nil {
            if pass.sequenceBefore < previousWatermark {
                mismatch = "pass \(index) starts at sequence \(pass.sequenceBefore), before the previous pass's \(previousWatermark)"
            }
            previousWatermark = pass.sequenceBefore
            for sequence in pass.inputs where mismatch == nil {
                if bySequence[sequence] == nil {
                    mismatch = "pass \(index) names sequence \(sequence), which is not a recorded input of the tick"
                } else if !named.insert(sequence).inserted {
                    mismatch = "sequence \(sequence) is named by more than one pass"
                }
            }
        }
        if mismatch == nil, named.count != bySequence.count {
            let missing = bySequence.keys.filter { !named.contains($0) }.sorted()
            mismatch = "no pass names the recorded inputs \(missing)"
        }

        let executingTickId = executingTickIdForPendingItems()
        var syncBroadcastOnly = applyInputs(initializeItems, executingTickId: executingTickId)
            .applied.shouldSyncBroadcastOnly
        // The turns below leave the queue as it is; nothing else changes it during replay, but
        // if something did across an await, the index is rebuilt from what is still queued.
        let queuedCount = pendingItems.count
        var queued = bySequence
        for (index, pass) in passes.enumerated() where mismatch == nil {
            if pendingItems.count != queuedCount {
                pendingItemScans += pendingItems.count
                let still = Set(pendingItems.map(\.sequence))
                queued = queued.filter { still.contains($0.key) }
            }
            var batch: [PendingItem] = []
            for sequence in pass.inputs {
                guard let item = queued.removeValue(forKey: sequence) else {
                    mismatch = "pass \(index) names sequence \(sequence), which is no longer queued"
                    break
                }
                batch.append(item)
            }
            if mismatch != nil { break }
            // No await between the restore and the turn: the turn numbers from the watermark.
            restoreSequenceWatermark(pass.sequenceBefore, tickId: tickId, point: "pass")
            let outcome = runInputTurn(batch, removingFromQueue: false)
            if outcome.syncBroadcastOnly { syncBroadcastOnly = true }
            if !outcome.record.isEmpty {
                await submitTurnRecord(outcome.record)
            }
            // Replay has no callers; this clears the turn's outcomes (`inputTurnResults`).
            resumeInputTurnWaiters(for: outcome.appliedItems)
        }
        if let mismatch {
            recordedPassMismatches[tickId] = mismatch
            logger.error("Re-evaluation: the record's passes don't match its inputs", metadata: [
                "tickId": .stringConvertible(tickId),
                "reason": .string(mismatch),
            ])
        }
        // Every input loaded for the frame, applied or (after a mismatch) not, in one scan.
        removePendingItems(inputs)
        return syncBroadcastOnly
    }

    /// Re-evaluation: why each replayed tick's record can't be reproduced: its passes don't match
    /// its inputs (`replayRecordedPasses`), or it holds a server input the land doesn't declare.
    private var recordedPassMismatches: [Int64: String] = [:]

    /// Re-evaluation: takes why `tickId`'s recorded passes didn't match its inputs, if they didn't.
    package func takeRecordedPassMismatch(for tickId: Int64) -> String? {
        recordedPassMismatches.removeValue(forKey: tickId)
    }

    /// Re-evaluation only: move the shared sequence counter forward to a recorded watermark.
    ///
    /// The counter is never moved back. If replay has already taken more numbers than live did,
    /// the extra server event shows up in the per-tick server-event comparison instead.
    private func restoreSequenceWatermark(_ watermark: Int64?, tickId: Int64, point: String) {
        guard mode == .reevaluation, let watermark else { return }
        if outputCollector.nextSequence <= watermark {
            outputCollector.nextSequence = watermark
        } else {
            // Replay has taken more numbers than live did; later ticks may mismatch because of
            // this, so log where it started.
            logger.warning("Re-evaluation sequence counter is past the recorded watermark", metadata: [
                "tickId": .stringConvertible(tickId),
                "point": .string(point),
                "counter": .stringConvertible(outputCollector.nextSequence),
                "watermark": .stringConvertible(watermark),
            ])
        }
    }

    private func runTick(allowWhenNoTickTask: Bool) async {
        // Check if task was cancelled before executing tick
        // This prevents ticks from running after shutdown has started
        guard !Task.isCancelled else { return }

        // The loop's tick is starting: a sync firing from now on no longer folds into it.
        if !allowWhenNoTickTask { nextTickDeadline = nil }

        // No tick body starts while frozen; a body already running is drained by `debugFreeze`.
        guard !debugFrozen else { return }
        debugBeginWork()
        defer { debugEndWork() }

        // A tickless land in re-evaluation still steps through the recorded ticks: each step
        // applies that tick's recorded inputs and flushes their events under it (#268).
        let tickHandler = definition.lifetimeHandlers.tickHandler
        if tickHandler == nil, mode == .live {
            if usesInTurnSync {
                // Tickless: the ready inputs run as input turns (or join the drain in progress).
                if !inputDrainScheduled {
                    inputDrainScheduled = true
                    await runInputDrain()
                }
                return
            }
            // Even if there's no tick handler, we still need to process pending actions
            // processPendingActions() will automatically advance tick counter if needed
            await processPendingActions(flushOutputsImmediately: true)
            return
        }

        // Double-check: if tickTask is nil, we're in shutdown, don't run (unless manually stepping)
        if !allowWhenNoTickTask {
            guard tickTask != nil else { return }
        }
        // A tick runs whole or not at all: none starts once the drain has started (a manual
        // step included), and the drain waits for one in flight before it takes the pending
        // inputs and runs the destroy handlers. Same synchronous segment as the start.
        // Re-evaluation: a replayed shutdown ended the replay; stop as past the recorded range.
        if mode == .reevaluation, shutdownTurnApplied {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        // `shutdownRequested`: a forced shutdown waits for the tick in flight, then applies its
        // turn; no tick starts in between (#382).
        guard !isDraining, !shutdownRequested else { return }
        ticksInFlight += 1
        defer { endTickInFlight() }

        // Use tickId for deterministic replay (increments with each tick)
        // Increment BEFORE processing pending actions so they can execute in this tick
        let tickId = nextTickId
        nextTickId += 1

        // In re-evaluation mode, stop when we exceed the recorded tick range (prevent simulation beyond record)
        if mode == .reevaluation, let source = reevaluationSource {
            let maxTickId = (try? await source.getMaxTickId()) ?? -1
            if tickId > maxTickId {
                tickTask?.cancel()
                tickTask = nil
                return
            }
        }

        // In-turn sync (live only): the whole turn (inputs, tick handler, events, sync plan and
        // commit, writer enqueue) runs without a suspension point; the recorder follows the turn.
        if usesInTurnSync, let transport, let handler = tickHandler {
            inTurnProbeForTesting?("turn-begin")
            if inTurnYieldForTesting {
                // Negative control (tests only): a suspension point inside the turn, which the
                // reentrancy probe must detect.
                await Task.yield()
            }
            let output = runTickTurn(handler: handler, tickId: tickId, transport: transport)
            await finishTickTurn(output)
            return
        }

        // Recorded sequence watermarks for this tick (re-evaluation only; nil for older records).
        var replayWatermarks: ReevaluationSequenceWatermarks?
        // A tickless land's recorded passes for this tick (3.1 on; empty otherwise).
        var replayPasses: [ReevaluationRecordedPass] = []

        // In re-evaluation mode, load actions, client events, and lifecycle events from ReevaluationSource.
        if mode == .reevaluation, let source = reevaluationSource {
            do {
                replayWatermarks = try await source.getSequenceWatermarks(for: tickId)
                replayPasses = try await source.getPasses(for: tickId)
                let recordedActions = try await source.getActions(for: tickId)
                let recordedClientEvents = try await source.getClientEvents(for: tickId)
                let recordedServerInputs = try await source.getServerInputs(for: tickId)
                let recordedLifecycleEvents = try await source.getLifecycleEvents(for: tickId)

                // Convert recorded actions to PendingItem
                for recordedAction in recordedActions {
                    // Find the action type handler by matching type identifier
                    guard let handler = definition.actionHandlers.first(where: { handler in
                        let actionType = handler.getActionType()
                        let actionTypeName = String(describing: actionType)

                        // Direct type name match (e.g., "AddGoldAction" == "AddGoldAction")
                        if actionTypeName == recordedAction.typeIdentifier {
                            return true
                        }

                        // Match last component (e.g., "Module.AddGoldAction" == "AddGoldAction")
                        if actionTypeName.split(separator: ".").last == recordedAction.typeIdentifier.split(separator: ".").last {
                            return true
                        }

                        return false
                    }) else {
                        logger.warning("Handler not found for recorded action type", metadata: [
                            "typeIdentifier": .string(recordedAction.typeIdentifier),
                        ])
                        continue
                    }

                    // Get the action type from handler (we know it's ActionPayload.Type)
                    let actionTypeAny = handler.getActionType()
                    guard let actionType = actionTypeAny as? any ActionPayload.Type else {
                        logger.warning("Action type is not ActionPayload", metadata: [
                            "typeIdentifier": .string(recordedAction.typeIdentifier),
                        ])
                        continue
                    }

                    // Convert resolver outputs back to ResolverOutput.
                    // In re-evaluation mode, we wrap them in AnyCodableResolverOutput for lazy decoding.
                    // The actual decoding happens when accessed via LandContext.subscript
                    var resolverOutputs: [String: any ResolverOutput] = [:]
                    for (key, recordedOutput) in recordedAction.resolverOutputs {
                        resolverOutputs[key] = AnyCodableResolverOutput(
                            typeIdentifier: recordedOutput.typeIdentifier,
                            value: recordedOutput.value
                        )
                    }

                    let pendingItem = PendingItem.action(
                        PendingActionItem(
                            sequence: recordedAction.sequence,
                            action: recordedAction.payload,
                            actionType: actionType,
                            playerID: PlayerID(recordedAction.playerID),
                            clientID: ClientID(recordedAction.clientID),
                            sessionID: SessionID(recordedAction.sessionID),
                            resolverOutputs: resolverOutputs,
                            resolvedAtTick: recordedAction.resolvedAtTick
                        )
                    )
                    pendingItems.append(pendingItem)
                }

                // Convert recorded client events to PendingItem
                for recordedClientEvent in recordedClientEvents {
                    let pendingItem = PendingItem.clientEvent(
                        PendingClientEventItem(
                            sequence: recordedClientEvent.sequence,
                            event: AnyClientEvent(
                                type: recordedClientEvent.typeIdentifier,
                                payload: recordedClientEvent.payload
                            ),
                            playerID: PlayerID(recordedClientEvent.playerID),
                            clientID: ClientID(recordedClientEvent.clientID),
                            sessionID: SessionID(recordedClientEvent.sessionID),
                            resolvedAtTick: recordedClientEvent.resolvedAtTick
                        )
                    )
                    pendingItems.append(pendingItem)
                }

                // Recorded server inputs (#387): replay needs none of the outside work. One this
                // land doesn't declare can't be reproduced: it fails the tick.
                for recorded in recordedServerInputs {
                    guard definition.serverInputHandlers[recorded.typeIdentifier] != nil else {
                        let reason = "recorded server input \(recorded.sequence) has type \(recorded.typeIdentifier), which the land doesn't declare"
                        recordedPassMismatches[tickId] = recordedPassMismatches[tickId] ?? reason
                        logger.error("Re-evaluation: a recorded server input can't be applied", metadata: [
                            "tickId": .stringConvertible(tickId),
                            "reason": .string(reason),
                        ])
                        continue
                    }
                    pendingItems.append(.serverInput(PendingServerInputItem(
                        sequence: recorded.sequence,
                        typeIdentifier: recorded.typeIdentifier,
                        payload: recorded.payload,
                        resolvedAtTick: recorded.resolvedAtTick
                    )))
                }

                // Convert recorded lifecycle events to PendingItem
                for recordedLifecycleEvent in recordedLifecycleEvents {
                    if recordedLifecycleEvent.kind == Self.shutdownLifecycleKind {
                        pendingItems.append(.shutdown(PendingShutdownItem(
                            sequence: recordedLifecycleEvent.sequence,
                            resolvedAtTick: recordedLifecycleEvent.resolvedAtTick
                        )))
                        continue
                    }
                    // A kind this build doesn't know can't be reproduced: it fails the tick,
                    // rather than being replayed as something else.
                    guard let kind = LifecycleKind(rawValue: recordedLifecycleEvent.kind) else {
                        let reason = "recorded lifecycle event \(recordedLifecycleEvent.sequence) has kind \(recordedLifecycleEvent.kind), which this build doesn't know"
                        recordedPassMismatches[tickId] = recordedPassMismatches[tickId] ?? reason
                        logger.error("Re-evaluation: a recorded lifecycle event can't be applied", metadata: [
                            "tickId": .stringConvertible(tickId),
                            "reason": .string(reason),
                        ])
                        continue
                    }

                    var resolverOutputs: [String: any ResolverOutput] = [:]
                    for (key, recordedOutput) in recordedLifecycleEvent.resolverOutputs {
                        resolverOutputs[key] = AnyCodableResolverOutput(
                            typeIdentifier: recordedOutput.typeIdentifier,
                            value: recordedOutput.value
                        )
                    }

                    let pendingItem = PendingItem.lifecycle(
                        PendingLifecycleItem(
                            sequence: recordedLifecycleEvent.sequence,
                            kind: kind,
                            playerID: recordedLifecycleEvent.playerID.map(PlayerID.init),
                            clientID: recordedLifecycleEvent.clientID.map(ClientID.init),
                            sessionID: recordedLifecycleEvent.sessionID.map(SessionID.init),
                            deviceID: recordedLifecycleEvent.deviceID,
                            isGuest: recordedLifecycleEvent.isGuest,
                            metadata: recordedLifecycleEvent.metadata,
                            resolverOutputs: resolverOutputs,
                            resolvedAtTick: recordedLifecycleEvent.resolvedAtTick
                        )
                    )
                    pendingItems.append(pendingItem)
                }
            } catch {
                logger.error("Error loading actions from ReevaluationSource", metadata: [
                    "tickId": .stringConvertible(tickId),
                    "error": .string(String(describing: error)),
                ])
            }
        }

        // Sequence watermark W1 (before inputs). Live: captured synchronously, with no await
        // since `nextTickId += 1`. Re-evaluation: restored after the source-loading awaits.
        restoreSequenceWatermark(replayWatermarks?.beforeInputs, tickId: tickId, point: "beforeInputs")
        let sequenceBeforeInputs = outputCollector.nextSequence

        // Process pending actions before tick handler
        // Don't flush outputs yet - defer until after tick handler to ensure
        // outputs include state changes from the tick handler
        // A failing input fails alone; the others and the tick handler still run.
        if replayPasses.isEmpty {
            await processPendingActions(flushOutputsImmediately: false)
        } else if await replayRecordedPasses(replayPasses, tickId: tickId) {
            await transport?.syncBroadcastOnlyFromTransport()
        }

        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID,
            tickId: tickId
        )

        // Sequence watermark W2 (before the tick handler). processPendingActions awaits after
        // its item loop, so inputs arriving then may have taken numbers since W1.
        restoreSequenceWatermark(replayWatermarks?.beforeTickHandler, tickId: tickId, point: "beforeTickHandler")
        let sequenceBeforeTickHandler = outputCollector.nextSequence

        // Execute handler synchronously - no copying needed
        // withMutableStateSync directly modifies state (actor isolation maintained)
        // A replayed shutdown frame (#382) runs no tick handler: live applied the shutdown as a
        // turn of its own, between ticks.
        if !shutdownTurnApplied {
            tickHandler?(&state, ctx)
        }

        // Update lastCommittedTickId after tick execution completes
        // This represents the world state's current committed tick
        lastCommittedTickId = tickId

        // Optionally record live per-tick state hash as ground truth for deterministic re-evaluation.
        if enableLiveStateHashRecording, let recorder = reevaluationRecorder {
            let enableStateSnapshotRecording = EnvHelpers.getEnvBool(
                key: EnvKeys.Runtime.stateSnapshotRecording,
                defaultValue: false
            )
            let (hash, snapshot) = liveStateHash(tickId: tickId)
            await recorder.setStateHash(tickId: tickId, stateHash: hash)
            if enableStateSnapshotRecording {
                await recorder.recordStateSnapshot(tickId: tickId, stateSnapshot: snapshot)
            }
        }

        // Flush deterministic outputs (emitted events + sync requests) for this tick.
        await flushOutputs(forTick: tickId)

        // Ensure we have a frame for every tick in live mode, even if no inputs occurred,
        // and store this tick's sequence watermarks on it.
        if let recorder = reevaluationRecorder {
            await recorder.record(
                tickId: tickId,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                sequenceBeforeInputs: sequenceBeforeInputs,
                sequenceBeforeTickHandler: sequenceBeforeTickHandler
            )
        }

        // Note: Tick handler does NOT trigger automatic network sync
        // Network synchronization is handled separately by the sync mechanism
    }

    // MARK: - In-turn sync: turns

    /// The events emitted for `tickId` (with a sequence below `sequenceBound`, when given), in
    /// sequence order, removed from the collector.
    private func takeEmittedEvents(forTick tickId: Int64, before sequenceBound: Int64? = nil) -> [EmittedEvent] {
        let taken: (EmittedEvent) -> Bool = { item in
            item.tickId == tickId && (sequenceBound.map { item.sequence < $0 } ?? true)
        }
        let emitted = outputCollector.emittedEvents
            .filter(taken)
            .sorted { $0.sequence < $1.sequence }
        if !emitted.isEmpty {
            outputCollector.emittedEvents.removeAll(where: taken)
        }
        return emitted
    }

    /// Whether the sync requests handlers made for `tickId` (taken from the collector) or a
    /// leave in `applied` ask for a sync phase. A broadcast-only request runs the full phase in a
    /// turn: the leave's effects go out with the turn's frames.
    private func takeSyncRequest(forTick tickId: Int64, applied: AppliedInputs?) -> Bool {
        let requests = outputCollector.syncRequestsByTick.removeValue(forKey: tickId)
        return requests?.syncNow == true
            || requests?.syncBroadcastOnly == true
            || applied?.shouldSyncBroadcastOnly == true
    }


    /// The output step of a turn, synchronous: the turn's events, then (when `wantsSync`) the sync
    /// phase, handed to the transport in this actor turn, and the result applied in it.
    ///
    /// While a legacy cycle holds the sync flag, the phase is left to a sync-only turn run by
    /// `endSync`; the events still go out now.
    private func runTurnOutputs(
        transport: any LandKeeperTransport,
        events: [EmittedEvent],
        wantsSync: Bool,
        joinSyncOnly: Bool = false
    ) {
        // A land without periodic sync runs the phase for joins waiting on it (#69): the turn
        // that consumed a join's input completes it in its own output step.
        var includeSync = wantsSync || (!hasPeriodicSync && transportHasJoinsAwaitingSync)
        if includeSync && isSyncing {
            includeSync = false
            inTurnSyncDue = false
            syncOnlyTurnAfterLegacyCycle = true
        }
        let result = transport.runSyncPhaseInTurn(
            state: state,
            events: events.map { InTurnServerEvent(event: $0.event, target: $0.target, sequence: $0.sequence) },
            includeSync: includeSync
        )
        applyInTurnSyncResult(result, transport: transport, joinSyncOnly: joinSyncOnly)
    }

    /// Applies what an in-turn sync phase did, in the same turn.
    ///
    /// - committed: the dirty flags are cleared now when the plan diffed every synced field.
    /// - deferred by back-pressure: nothing was planned, so the dirty flags and the adapter's
    ///   queued events stay. A land with periodic sync relies on its next sync-only turn; one
    ///   without gets one sync-only turn once the writer drains.
    /// - failed: the flags stay set. A land with periodic sync relies on its next sync-only turn;
    ///   one without gets a repair sync-only turn while the adapter allows it.
    ///
    /// `joinSyncOnly`: the phase ran only for ready joins, outside a periodic land's cadence; if
    /// back-pressure defers it, such phases stop until a sync commits (`periodicJoinSyncAllowed`).
    private func applyInTurnSyncResult(_ result: InTurnSyncResult, transport: any LandKeeperTransport, joinSyncOnly: Bool = false) {
        switch result {
        case let .committed(clearDirtyFlags):
            if clearDirtyFlags {
                state.clearDirty()
            }
            inTurnSyncDue = false
            joinSyncRetryFailures = 0
            joinSyncWaitsForCommit = false
            inTurnProbeForTesting?("sync-committed")
            // Joins left over a commit's budget: the next sync-only turn completes them.
            if !hasPeriodicSync && transportHasJoinsAwaitingSync {
                scheduleJoinSyncTurn(after: .zero)
            }
        case .skipped:
            inTurnSyncDue = false
        case .deferredBackPressure:
            inTurnSyncDue = false
            inTurnDeferredTurns += 1
            if joinSyncOnly { joinSyncWaitsForCommit = true }
            if !hasPeriodicSync {
                retrySyncOnlyTurnAfterWriterDrain(transport: transport)
            }
        case let .failed(repairAllowed):
            inTurnSyncDue = false
            if repairAllowed && !hasPeriodicSync {
                scheduleRepairSyncOnlyTurn()
            } else if !hasPeriodicSync && transportHasJoinsAwaitingSync {
                // Past the repair limit, joins still wait: retry with a doubling delay, so a plan
                // that keeps failing gives a bounded number of turns before the joins time out.
                joinSyncRetryFailures += 1
                let doublings = min(joinSyncRetryFailures - 1, 16)
                let delay = Self.inTurnRepairDelay * (1 << doublings)
                joinSyncRetryDelaysForTesting.append(delay)
                scheduleJoinSyncTurn(after: delay)
            }
        case .notRequested, .unsupported:
            break
        }
    }

    /// What a tick turn leaves for the work after it (the recorder).
    private struct TickTurnOutput {
        let record: ReevaluationTickRecord
    }

    /// One tick turn, synchronous from the first input to the writer enqueue.
    ///
    /// Applies the ready inputs, runs the tick handler, takes the events emitted in this tick and
    /// hands them to the transport in emit order, with the sync phase when it is due
    /// (coincident-sync rule) or a handler requested one, all in this actor turn. Being
    /// non-async, it cannot contain an `await`; the recorder submission is returned for
    /// `finishTickTurn`.
    private func runTickTurn(
        handler: (inout State, LandContext) -> Void,
        tickId: Int64,
        transport: any LandKeeperTransport
    ) -> TickTurnOutput {
        takePendingFold(transport: transport)
        // Sequence watermark W1 (before inputs).
        let sequenceBeforeInputs = outputCollector.nextSequence
        // A failing input fails alone; the others and the tick handler still run (`applyInputs`).
        let applied = applyInputs(readyPendingItemsInOrder(), executingTickId: tickId).applied

        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID,
            tickId: tickId
        )
        // Sequence watermark W2 (before the tick handler).
        let sequenceBeforeTickHandler = outputCollector.nextSequence
        handler(&state, ctx)
        lastCommittedTickId = tickId

        var stateHash: String?
        var stateSnapshot: StateSnapshot?
        if enableLiveStateHashRecording, reevaluationRecorder != nil {
            let (hash, snapshot) = liveStateHash(tickId: tickId)
            stateHash = hash
            if EnvHelpers.getEnvBool(key: EnvKeys.Runtime.stateSnapshotRecording, defaultValue: false) {
                stateSnapshot = snapshot
            }
        }

        let emitted = takeEmittedEvents(forTick: tickId)
        // Always take this tick's requests, so a folded sync does not leave them in the collector.
        let requested = takeSyncRequest(forTick: tickId, applied: applied)
        // A join this turn made ready (its OnJoin consumed, its session registered) flips in
        // this turn's sync phase rather than at the next periodic sync (#69): its JoinResponse
        // then waits for the tick that applies OnJoin only. The turn's sync is a full one, so
        // the members get this turn's changes now too, one sync earlier than the cadence.
        // (A land without periodic sync runs the phase for joins anyway: `runTurnOutputs`.)
        let cadenceSync = inTurnSyncDue || requested
        let joinSync = !cadenceSync && periodicJoinSyncAllowed
        if joinSync {
            // Tick and sync work in one turn that is not a fold: counted apart, so turn timing
            // can tell these turns from folded ones.
            joinSyncTicks += 1
            if transportRecordsFolds { transport.noteInTurnJoinSyncTick() }
        }
        runTurnOutputs(transport: transport, events: emitted, wantsSync: cadenceSync || joinSync, joinSyncOnly: joinSync)
        inTurnProbeForTesting?("turn-end")

        var record = makeTurnRecord(tickId: tickId, applied: applied, emitted: emitted)
        record.stateHash = stateHash
        record.stateSnapshot = stateSnapshot
        record.sequenceBeforeInputs = sequenceBeforeInputs
        record.sequenceBeforeTickHandler = sequenceBeforeTickHandler
        return TickTurnOutput(record: record)
    }

    /// At a tick turn's start: the fold it carries, if any, with how late the turn started
    /// against the deadline the sync folded on (#232). Once per turn. A fold whose sync already
    /// ran in a sync-only turn (`inTurnSyncDue` cleared) is not this turn's and is dropped.
    private func takePendingFold(transport: any LandKeeperTransport) {
        guard let fold = pendingFold else { return }
        pendingFold = nil
        guard inTurnSyncDue else { return }
        let start = tickClockForTesting ?? ContinuousClock.now
        let report = InTurnSyncFold(
            overdueAtFold: fold.overdueAtFold,
            tickLateness: start - fold.deadline,
            coincidentWindow: coincidentSyncWindow
        )
        if report.isLate { lateFoldedSyncs += 1 }
        if transportRecordsFolds { transport.noteInTurnSyncFold(report) }
    }

    /// After a tick turn: one recorder submission with everything the turn recorded. Live mode
    /// records a frame for every tick, even without inputs.
    private func finishTickTurn(_ output: TickTurnOutput) async {
        await submitTurnRecord(output.record)
    }

    /// The record of a turn's inputs and server events for `tickId`.
    private func makeTurnRecord(
        tickId: Int64,
        applied: AppliedInputs,
        emitted: [EmittedEvent]
    ) -> ReevaluationTickRecord {
        ReevaluationTickRecord(
            tickId: tickId,
            actions: applied.recordedActions,
            clientEvents: applied.recordedClientEvents,
            lifecycleEvents: applied.recordedLifecycleEvents,
            serverEvents: emitted.map { item in
                ReevaluationRecordedServerEvent(
                    kind: "serverEvent",
                    sequence: item.sequence,
                    tickId: item.tickId,
                    typeIdentifier: item.event.type,
                    payload: item.event.payload,
                    target: ReevaluationEventTargetRecord.from(item.target)
                )
            },
            serverInputs: applied.recordedServerInputs
        )
    }

    /// What OnInitialize did, read right after it: the server events emitted for `tickId` after
    /// its lifecycle `sequence` (not removed from the collector) and the state hash.
    private func makeInitializeRecord(sequence: Int64, tickId: Int64) -> ReevaluationRecordedInitialize {
        let events = outputCollector.emittedEvents
            .filter { $0.tickId == tickId && $0.sequence > sequence }
            .sorted { $0.sequence < $1.sequence }
        return ReevaluationRecordedInitialize(
            sequence: sequence,
            serverEvents: events.map { item in
                ReevaluationRecordedServerEvent(
                    kind: "serverEvent",
                    sequence: item.sequence,
                    tickId: item.tickId,
                    typeIdentifier: item.event.type,
                    payload: item.event.payload,
                    target: ReevaluationEventTargetRecord.from(item.target)
                )
            },
            stateHash: enableLiveStateHashRecording ? liveStateHash(tickId: tickId).hash : nil
        )
    }

    /// Ticks (and initialize) whose live state hash could not be computed and were recorded as
    /// `ReevaluationEngine.unavailableHash`.
    public var stateHashUnavailableCount: Int { stateHashUnavailableTotal }

    /// The full-state hash of the current state for live recording (#180). A conversion that
    /// throws never stops the tick: the hash is recorded as unavailable, logged and counted, and
    /// replay reports that tick as unverifiable.
    private func liveStateHash(tickId: Int64) -> (hash: String, snapshot: StateSnapshot) {
        let (hash, snapshot) = ReevaluationEngine.calculateStateHashAndSnapshot(state)
        if ReevaluationEngine.isUnavailableHash(hash) {
            stateHashUnavailableTotal += 1
            logger.error("State hash unavailable; tick recorded without a hash", metadata: [
                "tickId": .stringConvertible(tickId),
                "reason": .string(hash),
                "unavailableCount": .stringConvertible(stateHashUnavailableTotal),
            ])
        }
        return (hash, snapshot)
    }

    /// The next sync-stream position. Callers take it only while the land records its sync
    /// stream, in the same synchronous segment as the entry.
    private func takeSyncStreamIndex() -> UInt64 {
        let index = syncStreamCounter
        syncStreamCounter += 1
        return index
    }

    // MARK: - Sync stream (record format 2.1), for the adapter while in-turn sync is on

    /// Whether this keeper records its sync stream: live, with a recorder, and in-turn sync on.
    /// The adapter asks it (through `assumeIsolated`, on the shared executor) before planning.
    package var recordsSyncStream: Bool {
        mode == .live && reevaluationRecorder != nil && usesInTurnSync
    }

    /// Where a plan reading the state now reads it.
    package func syncReadPosition() -> SyncReadPosition {
        SyncReadPosition(observedTickId: lastCommittedTickId, sequence: outputCollector.nextSequence)
    }

    /// The kind of the turn whose sync phase is running (`tick` or `syncOnly`).
    package var currentSyncTurnKind: ReevaluationRecordedSyncOutput.TurnKind {
        inTurnSyncTurnKind
    }

    /// Numbers and records one sync output: `make` gets its `streamIndex` and `index`. Called in
    /// the same synchronous segment as the commit it describes; the record is submitted after
    /// every earlier submission without waiting.
    package func recordSyncOutput(
        observedTickId: Int64?,
        _ make: (_ streamIndex: UInt64, _ index: Int) -> ReevaluationRecordedSyncOutput
    ) {
        guard reevaluationRecorder != nil else { return }
        let index: Int
        if let cursorTick = syncOutputIndexCursor.observedTickId, cursorTick == observedTickId {
            index = syncOutputIndexCursor.count
        } else {
            index = 0
        }
        syncOutputIndexCursor = (observedTickId, index + 1)
        let output = make(takeSyncStreamIndex(), index)
        enqueueRecorderSubmission(ReevaluationTickRecord(
            tickId: max(observedTickId ?? lastCommittedTickId, 0),
            syncOutputs: [output]
        ))
    }

    /// Numbers and records one marker: `make` gets its `streamIndex`. A seed goes into the frame
    /// of its `observedTickId`, a clear into the current tick's.
    ///
    /// `outsideTurn`: the marker is recorded outside any keeper turn (a disconnect's or a
    /// superseded session's clear). On a tickless land it is then its own turn record, so no
    /// later turn has to close it (#327).
    package func recordSyncMarker(
        outsideTurn: Bool = false,
        _ make: (_ streamIndex: UInt64) -> ReevaluationRecordedSyncMarker
    ) {
        guard reevaluationRecorder != nil else { return }
        let marker = make(takeSyncStreamIndex())
        enqueueRecorderSubmission(ReevaluationTickRecord(
            tickId: max(marker.observedTickId ?? lastCommittedTickId, 0),
            syncMarkers: [marker]
        ), endsTurn: outsideTurn && isTickless)
    }

    /// Submits `record` after every earlier submission, without waiting for it; returns the
    /// submission (nil without a recorder).
    @discardableResult
    private func enqueueRecorderSubmission(_ record: ReevaluationTickRecord, endsTurn: Bool = false) -> Task<Void, Never>? {
        guard let recorder = reevaluationRecorder else { return nil }
        recorderSubmissionCount += 1
        return recorderSubmissions.submit { await recorder.recordTick(record, endsTurn: endsTurn) }
    }

    /// Ends a tickless land's turn record after every earlier submission, if the turn enqueued
    /// anything since `mark` (`recorderSubmissionCount` at its start). Called in the turn's
    /// synchronous segment, as its last enqueue.
    private func enqueueTicklessTurnEnd(since mark: Int) {
        guard isTickless, recorderSubmissionCount != mark, let recorder = reevaluationRecorder else { return }
        recorderSubmissionCount += 1
        recorderSubmissions.submit { await recorder.endTurn() }
    }

    /// Tests only: waits until every recorder submission so far is recorded.
    func waitForRecorderSubmissionsForTesting() async {
        await recorderSubmissions.waitForAll()
    }

    /// Tests only: waits until no tickless input task is in flight (`debugBeginWork`, counted
    /// before the call that started it returned), then until its recorder submissions are in.
    func waitForInFlightWorkForTesting() async {
        while debugInFlightWork > 0 {
            debugNextWaiterID &+= 1
            let waiterID = debugNextWaiterID
            await withCheckedContinuation { continuation in
                debugDrainWaiters[waiterID] = continuation
            }
        }
        await recorderSubmissions.waitForAll()
    }

    /// Tests only: the next sync-stream position (how many entries were numbered).
    func syncStreamCounterForTesting() -> UInt64 {
        syncStreamCounter
    }

    /// Submits `record` after every earlier submission (turn order) and returns once it is
    /// recorded. No-op without a recorder. On a tickless land the record ends the turn's
    /// record (#327). It is enqueued before the first `await`, in the caller's synchronous
    /// segment, so it is the turn's last enqueue; the hold (tests) comes after it.
    private func submitTurnRecord(_ record: ReevaluationTickRecord) async {
        let submission = enqueueRecorderSubmission(record, endsTurn: isTickless)
        await holds.at(.turnRecord)
        await submission?.value
    }

    /// A sync-only turn (no inputs, no tick): the sync phase on the current state, synchronous,
    /// with the dirty-flag clear in the same turn. While a legacy cycle holds the sync flag, it
    /// runs again after that cycle's `endSync` instead.
    private func runSyncOnlyTurn(transport: any LandKeeperTransport, joinSyncOnly: Bool = false) {
        guard !isSyncing else {
            syncOnlyTurnAfterLegacyCycle = true
            return
        }
        inTurnProbeForTesting?("turn-begin")
        inTurnSyncTurnKind = .syncOnly
        defer { inTurnSyncTurnKind = .tick }
        let mark = recorderSubmissionCount
        let result = transport.runSyncPhaseInTurn(state: state, events: [], includeSync: true)
        applyInTurnSyncResult(result, transport: transport, joinSyncOnly: joinSyncOnly)
        // A tickless land's sync-only turn is its own turn record (#327); a tick land's sync
        // outputs stay with the current tick's.
        enqueueTicklessTurnEnd(since: mark)
        inTurnProbeForTesting?("turn-end")
    }

    /// A sync-only turn, if this keeper still runs in-turn sync (scheduled turns).
    private func runSyncOnlyTurnIfInTurn() {
        guard usesInTurnSync, let transport else { return }
        runSyncOnlyTurn(transport: transport)
    }

    /// After a deferred phase on a land without periodic sync: one sync-only turn once the writer
    /// has drained its sync cycle elements (at most one pending).
    private func retrySyncOnlyTurnAfterWriterDrain(transport: any LandKeeperTransport) {
        guard !inTurnDrainRetryPending else { return }
        inTurnDrainRetryPending = true
        Task { [weak self] in
            await transport.waitForWriterDrainForInTurnSync()
            await self?.runRetriedSyncOnlyTurn()
        }
    }

    private func runRetriedSyncOnlyTurn() {
        inTurnDrainRetryPending = false
        runSyncOnlyTurnIfInTurn()
    }

    /// Failed sync phases in a row that left joins waiting, past the repair limit (backoff).
    private var joinSyncRetryFailures = 0
    /// A sync-only turn for waiting joins is scheduled.
    private var joinSyncTurnPending = false
    /// Sync-only turns run for waiting joins (tests).
    private(set) var joinSyncTurnsForTesting = 0
    /// The retry delays scheduled past the repair limit, in order (tests).
    private(set) var joinSyncRetryDelaysForTesting: [Duration] = []

    /// One sync-only turn for joins waiting on a committed sync phase, after `delay` (at most one
    /// pending). It runs only if joins still wait then.
    private func scheduleJoinSyncTurn(after delay: Duration) {
        guard !joinSyncTurnPending else { return }
        joinSyncTurnPending = true
        Task { [weak self] in
            if delay > .zero {
                try? await safeTaskSleep(for: delay)
            }
            await self?.runJoinSyncTurn()
        }
    }

    private func runJoinSyncTurn() {
        joinSyncTurnPending = false
        guard !isDraining, transportHasJoinsAwaitingSync, let transport else { return }
        joinSyncTurnsForTesting += 1
        runSyncOnlyTurn(transport: transport)
    }

    /// After a failed plan on a land without periodic sync: one repair sync-only turn after
    /// `inTurnRepairDelay` (at most one pending; the adapter bounds failures in a row).
    private func scheduleRepairSyncOnlyTurn() {
        guard !inTurnRepairPending else { return }
        inTurnRepairPending = true
        Task { [weak self] in
            try? await safeTaskSleep(for: Self.inTurnRepairDelay)
            await self?.runRepairSyncOnlyTurn()
        }
    }

    private func runRepairSyncOnlyTurn() {
        inTurnRepairPending = false
        inTurnRepairTurns += 1
        runSyncOnlyTurnIfInTurn()
    }

    // MARK: - In-turn sync: tickless input turns

    /// Ticks with a handler running (`runTick`), possibly suspended in their awaits. A count,
    /// not a flag: a manual `stepTickOnce` can overlap a suspended tick, and the drain waits for
    /// all of them.
    private var ticksInFlight = 0
    private var tickIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private func endTickInFlight() {
        ticksInFlight -= 1
        guard ticksInFlight == 0 else { return }
        let waiters = tickIdleWaiters
        tickIdleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Returns once no tick is in flight. Called by the drain after `isDraining` is set, so no
    /// new tick starts meanwhile.
    private func waitForTickInFlight() async {
        guard ticksInFlight > 0 else { return }
        await withCheckedContinuation { tickIdleWaiters.append($0) }
    }

    /// Set when the drain starts the destroy handlers; `applyPendingItem` applies nothing after.
    private var destroyHandlersStarted = false

    /// Lets tickless intake held by a freeze (`debugWaitWhileFrozen`) continue when the drain
    /// starts: each re-checks `rejectIfLandClosed` and gets `.landClosed`, instead of waiting for
    /// a resume that never comes.
    private func releaseHeldInputsForDrain() {
        dropServerInputsHeldWhileFrozen()
        let held = debugHeldInputs
        debugHeldInputs.removeAll()
        held.forEach { $0.resume() }
    }

    /// The rest of the shutdown turn (#382), in the segment that applied its input
    /// (`applyInputs`): the players are cleared there; here every input still queued is
    /// dropped (its caller gets `.landClosed`), the drain flag is set, so intake is closed and
    /// no tick starts, and intake held by a freeze is released to be rejected. The destroy
    /// follows in `forceShutdown`. The turn changes no land state and requests no sync.
    ///
    /// In re-evaluation the shutdown only ends the replay: the recorded inputs left are dropped,
    /// the tick that replays it runs no tick handler, and no later tick runs (`runTick`). The
    /// viewers stay, the land stays open, and its own empty-room destroy still applies.
    private func completeShutdownTurn() {
        shutdownTurnApplied = true
        guard mode == .live else {
            pendingItems.removeAll()
            return
        }
        dropPendingInputs(reason: "forceShutdown")
        drainFlag.set(cause: .forceShutdown)
        releaseHeldInputsForDrain()
        resumeShutdownTurnWaiters()
    }

    /// `forceShutdown` on a tickless land, waiting for its shutdown input's turn, or for the
    /// input to be dropped by a drain that started first.
    private var shutdownTurnWaiters: [CheckedContinuation<Void, Never>] = []

    private func resumeShutdownTurnWaiters() {
        let waiters = shutdownTurnWaiters
        shutdownTurnWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Set by the shutdown turn (#382). In re-evaluation, the tick that replays it runs no
    /// tick handler, so its state hash is the last tick's, as live recorded it.
    private var shutdownTurnApplied = false

    /// Removes every pending input and fails the callers waiting for those inputs' turns with
    /// `LandInputRejection.landClosed`. Callers of inputs already applied (their outcome in
    /// `inputTurnResults`, waiting for the turn's record) are left to that turn.
    private func dropPendingInputs(reason: String) {
        guard !pendingItems.isEmpty else { return }
        let dropped = pendingItems
        pendingItems.removeAll()
        // A drain that started before the shutdown turn: `forceShutdown` waits for it instead.
        if dropped.contains(where: \.isShutdown) { resumeShutdownTurnWaiters() }
        let droppedServerInputs = dropped.filter { if case .serverInput = $0 { true } else { false } }.count
        serverInputsInFlight = max(0, serverInputsInFlight - droppedServerInputs)
        var failed: [CheckedContinuation<AnyCodable, any Error>] = []
        for item in dropped {
            if let waiter = inputTurnWaiters.removeValue(forKey: item.sequence) {
                failed.append(waiter)
            }
            // A legacy caller whose input was queued behind the shutdown, in the same pass
            // (#382): its own pass answers it with `.landClosed`, as if it had applied it.
            if legacyPassCallers.contains(item.sequence) {
                legacyPassResults[item.sequence] = .failure(LandInputRejection.landClosed)
                legacyPassAppliedBy[item.sequence] = item.sequence
            }
            if ticklessJobTurns.remove(item.sequence) != nil {
                fillActionSlot(item.sequence, with: .failure(LandInputRejection.landClosed))
            }
        }
        logger.info("Pending inputs dropped: the land is closing", metadata: [
            "reason": .string(reason),
            "dropped": .stringConvertible(dropped.count),
            "failedWaiters": .stringConvertible(failed.count),
        ])
        failed.forEach { $0.resume(throwing: LandInputRejection.landClosed) }
    }

    /// Waits until the input with `sequence` has run in an input turn, and returns its response:
    /// the action's response, an empty one for other inputs, or the handler's error.
    ///
    /// Returns an empty response at once when the input is neither pending nor waiting for its
    /// turn's record: a turn already applied it and nobody kept its outcome. Only a server
    /// input's task registers late (its outcome is empty); actions, client events, joins and
    /// leaves register in the same synchronous segment as their append, so their caller always
    /// gets its own outcome, an error included.
    private func awaitInputTurn(sequence: Int64) async throws -> AnyCodable {
        try await withCheckedThrowingContinuation { continuation in
            guard inputTurnResults[sequence] != nil
                || pendingItems.contains(where: { $0.sequence == sequence })
            else {
                continuation.resume(returning: AnyCodable(()))
                return
            }
            inputTurnWaiters[sequence] = continuation
            scheduleInputDrain()
        }
    }

    /// Schedules the input drain unless one is scheduled or running.
    private func scheduleInputDrain() {
        guard !inputDrainScheduled else { return }
        inputDrainScheduled = true
        Task { [weak self] in
            await self?.runInputDrain()
        }
    }

    /// Runs input turns until no ready input is left. Each turn takes an ordered snapshot of at
    /// most `inputTurnBatchLimit` ready inputs; inputs arriving during a turn go to a later one.
    /// Between turns the drain yields, so sync-only turns and other jobs interleave whether or
    /// not a recorder is attached. The caller has set `inputDrainScheduled`.
    private func runInputDrain() async {
        await holds.at(.inputDrain)
        while true {
            let batch = Array(readyPendingItemsInOrder().prefix(Self.inputTurnBatchLimit))
            if batch.isEmpty { break }
            let mark = recorderSubmissionCount
            let outcome = runInputTurn(batch)
            if !outcome.record.isEmpty {
                await submitTurnRecord(outcome.record)
            } else {
                enqueueTicklessTurnEnd(since: mark)
            }
            resumeInputTurnWaiters(for: outcome.appliedItems)
            await Task.yield()
        }
        inputDrainScheduled = false
        inTurnProbeForTesting?("input-drain-end")
    }

    /// The input-turn outcome of each waiting caller, kept until the turn's record is submitted.
    private var inputTurnResults: [Int64: Result<AnyCodable, any Error>] = [:]

    /// What an input turn did: its record and the inputs it applied (a failed one included).
    private struct InputTurnOutcome {
        var record: ReevaluationTickRecord
        var appliedItems: [PendingItem]
        /// Whether a leave asks for a broadcast-only sync (the legacy path's flag).
        var syncBroadcastOnly: Bool
    }

    /// One tickless input turn, synchronous: applies `batch`, takes the events emitted and the
    /// sync requests made, and hands them to the transport with the sync phase when requested.
    /// The outcomes of the applied inputs wait in `inputTurnResults` until the record is in.
    ///
    /// An input P whose handler throws fails alone, as on the legacy path (`applyInputs`): P's
    /// caller gets P's error, P's events are dropped, and every other input of the batch is
    /// applied and its caller gets its own outcome. P is recorded in order, so replay fails it
    /// the same way. The tick's sync requests cannot be split per input: a request P made
    /// before it threw is consumed by this turn, so P's partial writes are kept and go out with
    /// it, as with any other change (a per-input savepoint is #87).
    private func runInputTurn(_ batch: [PendingItem], removingFromQueue: Bool = true) -> InputTurnOutcome {
        inTurnProbeForTesting?("turn-begin")
        inTurnProbeForTesting?("input-batch-\(batch.count)")
        let executingTickId = executingTickIdForPendingItems()
        let sequenceBefore = outputCollector.nextSequence
        // A failing input fails alone (its caller gets its error); the rest of the batch goes
        // on (`applyInputs`). Its events were dropped there.
        let application = applyInputs(batch, executingTickId: executingTickId, removingFromQueue: removingFromQueue)
        let applied = application.applied
        var emitted: [EmittedEvent] = []
        if !batch.isEmpty, let transport, usesInTurnSync {
            emitted = takeEmittedEvents(forTick: executingTickId)
            let wantsSync = takeSyncRequest(forTick: executingTickId, applied: applied)
            runTurnOutputs(transport: transport, events: emitted, wantsSync: wantsSync)
        }
        inTurnProbeForTesting?("turn-end")
        for item in batch {
            inputTurnResults[item.sequence] = application.outcomes[item.sequence]
        }
        var record = makeTurnRecord(tickId: executingTickId, applied: applied, emitted: emitted)
        // A tickless land's turn is one pass (#325, #321).
        if !applied.appliedOrder.isEmpty {
            record.passes = [ReevaluationRecordedPass(sequenceBefore: sequenceBefore, inputs: applied.appliedOrder)]
        }
        return InputTurnOutcome(record: record, appliedItems: batch, syncBroadcastOnly: applied.shouldSyncBroadcastOnly)
    }

    /// Resumes the callers of `batch` with their outcomes, after the turn was recorded (as the
    /// legacy path records before it returns).
    private func resumeInputTurnWaiters(for batch: [PendingItem]) {
        for item in batch {
            let result = inputTurnResults.removeValue(forKey: item.sequence) ?? .success(AnyCodable(()))
            if ticklessJobTurns.remove(item.sequence) != nil {
                fillActionSlot(item.sequence, with: result)
            } else {
                inputTurnWaiters.removeValue(forKey: item.sequence)?.resume(with: result)
            }
        }
    }

    private func configureSyncLoop(interval: Duration) async {
        syncTask?.cancel()
        let phaseOffset = loopPhaseOffset(interval: interval)
        appliedSyncPhaseOffset = phaseOffset
        syncTask = Task { [weak self] in
            if phaseOffset > .zero {
                try? await safeTaskSleep(for: phaseOffset)
            }
            guard let self = self else { return }

            var nextSyncTime = ContinuousClock.now + interval

            while !Task.isCancelled {
                let now = ContinuousClock.now

                // If we're already past the scheduled time, execute immediately
                // Otherwise, sleep until the scheduled time
                if now < nextSyncTime {
                    try? await Task.sleep(until: nextSyncTime, clock: .continuous)
                }

                await self.runSync()

                // Fixed-rate scheduling: calculate next time from the scheduled time, not from now
                // This maintains a consistent sync rate even if execution takes longer than interval
                // If execution time exceeds interval, we skip ahead to maintain the rate
                nextSyncTime = nextSyncTime + interval

                // If we're still behind schedule after skipping, continue skipping
                // This prevents the loop from getting stuck if execution time consistently exceeds interval
                while nextSyncTime <= ContinuousClock.now {
                    nextSyncTime = nextSyncTime + interval
                }
            }
        }
    }

    private func runSync() async {
        // Check if task was cancelled before executing sync
        // This prevents sync from running after shutdown has started
        guard !Task.isCancelled else { return }

        // Double-check: if syncTask is nil, we're in shutdown, don't run
        guard syncTask != nil else { return }

        // The only sync while frozen is the settle cycle run by the transport.
        guard !debugFrozen else { return }

        // Execute optional read-only callback if provided
        // This callback is read-only and should NOT modify state
        if let handler = definition.lifetimeHandlers.syncHandler {
            let ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID,
                servicesOverride: LandServices(),
                tickId: lastCommittedTickId
            )
            // Pass state as value (read-only) to emphasize that it should not be modified
            handler(state, ctx)
        }

        // In-turn sync: a sync-only turn at the sync loop's own interval, unless a tick is due
        // within the coincident-sync window: then the sync folds into that tick turn, so it
        // never overtakes a tick due at the same instant. An overdue tick (deadline already
        // past, the tick loop late) counts as due: the frame then waits for that late tick,
        // where the legacy path would send it now with the pre-tick state. Kept by design.
        if usesInTurnSync, let transport {
            let now = syncClockForTesting ?? ContinuousClock.now
            if tickTask != nil, let deadline = nextTickDeadline,
               deadline - now <= coincidentSyncWindow
            {
                // Counted once per tick turn the sync waits for: a tick late by more than a sync
                // interval folds the next iteration into the same turn, which is one cycle.
                // The transport hears of it when that tick turn starts (`takePendingFold`).
                // Keyed on the pending fold, not on `inTurnSyncDue`: a freeze drops the
                // pending fold but keeps the due sync, and the fold after the resume counts.
                if pendingFold == nil {
                    foldedSyncs += 1
                    let overdue = deadline < now
                    if overdue { overdueFoldedSyncs += 1 }
                    pendingFold = (deadline, overdue)
                }
                inTurnSyncDue = true
                return
            }
            runSyncOnlyTurn(transport: transport)
            return
        }

        // Sync is read-only: only triggers synchronization mechanism
        // It does not modify state
        await transport?.syncNowFromTransport()
    }

    /// The OnJoin resolvers of a join that already inserted its entry (`entryGeneration`). If
    /// they throw or time out (#104), the join fails: in the segment where the throw resumes, the
    /// entry goes if it is still this join's, so `players` keeps no player that never joined, and
    /// an empty land gets back the destroy timer the insert cancelled.
    private func executeOnJoinResolvers(
        resolverContext: ResolverContext,
        landContext: LandContext,
        playerID: PlayerID,
        entryGeneration: Epoch
    ) async throws -> LandContext {
        do {
            return try await ResolverExecutor.executeResolvers(
                executors: definition.lifetimeHandlers.onJoinResolverExecutors,
                resolverContext: resolverContext,
                landContext: landContext
            )
        } catch {
            if players[playerID]?.generation == entryGeneration {
                players.removeValue(forKey: playerID)
                scheduleDestroyIfNeeded()
            }
            throw error
        }
    }

    private func scheduleDestroyIfNeeded() {
        guard players.isEmpty, let delay = definition.config.destroyWhenEmptyAfter else { return }

        destroyTask?.cancel()
        destroyTask = Task { [weak self] in
            do {
                try await safeTaskSleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.shutdownIfIdle(cause: .emptyTimeout)
        }
    }

    private func shutdownIfIdle(cause: LandDestructionCause) async {
        // Destruction runs once; a second caller (the empty-room timer and `forceShutdown`)
        // waits for the one in progress.
        if let drainTask {
            await drainTask.value
            return
        }
        guard players.isEmpty else { return }
        // Same synchronous segment as the emptiness check: joins from now on are rejected.
        drainFlag.set(cause: cause)
        releaseHeldInputsForDrain()
        // No action job can be delivered any more; their callers get `.landClosed`.
        cancelAllActionJobs()
        let task = Task { await self.drainAfterIdleCheck() }
        drainTask = task
        await task.value
    }

    /// The destruction proper: stop the loops, run the destroy handlers, notify the transport.
    private func drainAfterIdleCheck() async {
        await holds.at(.drainStart)
        // Cancel tick and sync tasks FIRST to prevent any new ticks/syncs from starting
        // This must be done before executing destroy handlers to ensure no ticks/syncs run after destroy
        tickTask?.cancel()
        tickTask = nil
        syncTask?.cancel()
        syncTask = nil

        destroyTask?.cancel()
        destroyTask = nil

        // No tick starts from now on (`isDraining`); one already running finishes whole.
        await waitForTickInFlight()
        // Intake has been closed since `isDraining` was set, so the pending inputs are all
        // there will be: they are dropped and their waiting callers get `.landClosed`.
        dropPendingInputs(reason: "drain")
        destroyHandlersStarted = true

        // A land whose initialization failed (#104) never ran OnInitialize: its destroy handlers
        // would act on (or save) a state that was never set up, so they are skipped.
        guard initializationFailure == nil else {
            await notifyTransportDestroyedAndRelease()
            return
        }

        // Each destroy handler: its resolvers first, then the handler in one synchronous
        // segment. Nothing else changes the state across those awaits: intake, deliveries and
        // every lifecycle append are rejected while draining, no tick starts, and no input is
        // pending. That is why the handlers need no ticket.
        if let onDestroyWhenEmptyHandler = definition.lifetimeHandlers.onDestroyWhenEmpty {
            let handlers = definition.lifetimeHandlers
            await runDestroyHandler(
                "onDestroyWhenEmpty",
                resolvers: handlers.onDestroyWhenEmptyResolverExecutors,
                handler: onDestroyWhenEmptyHandler,
                stateReadAfterwards: handlers.onFinalize != nil || handlers.afterFinalize != nil
                    || handlers.onShutdown != nil
            )
        }
        if let onFinalizeHandler = definition.lifetimeHandlers.onFinalize {
            let handlers = definition.lifetimeHandlers
            await runDestroyHandler(
                "OnFinalize",
                resolvers: handlers.onFinalizeResolverExecutors,
                handler: onFinalizeHandler,
                stateReadAfterwards: handlers.afterFinalize != nil || handlers.onShutdown != nil
            )
        }

        // Execute AfterFinalize handler (async cleanup)
        if let afterFinalizeHandler = definition.lifetimeHandlers.afterFinalize {
            let snapshot = state
            let ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID
            )
            await afterFinalizeHandler(snapshot, ctx)
        }

        // Legacy OnShutdown handler (deprecated)
        if let handler = definition.lifetimeHandlers.onShutdown {
            let snapshot = state
            await handler(snapshot)
        }

        // Notify transport that land has been destroyed
        // This allows transport layer to perform cleanup (e.g., remove from LandManager)
        // Note: tickTask and syncTask were already cancelled at the start of shutdownIfIdle
        await notifyTransportDestroyedAndRelease()
    }

    /// The destruction's last call to the transport, `onLandDestroyed`, then this instance drops
    /// its link to it. The transport (the adapter) holds this keeper, so the link is a reference
    /// cycle: kept, it would keep the keeper, its state and the adapter alive after the land is
    /// gone (#346). Dropped by this instance at the end of its own teardown, after the last call.
    private func notifyTransportDestroyedAndRelease() async {
        await transport?.onLandDestroyed()
        destructionFinished = true
        releasedTransport = ReleasedLandTransport(landID: actualLandID ?? definition.id, logger: logger)
        setTransport(nil)
    }

    /// One destroy handler (OnDestroyWhenEmpty, OnFinalize): its resolvers, then the handler
    /// in one synchronous segment. A resolver or handler failure is logged; the drain goes on.
    ///
    /// No ticket is captured across the resolvers: by now intake is closed (every input and
    /// lifecycle append checks `isDraining`), no tick runs and nothing is pending, so nothing
    /// else can change the state before the handler's segment.
    private func runDestroyHandler(
        _ name: String,
        resolvers: [any AnyResolverExecutor],
        handler: @Sendable (inout State, LandContext) throws -> Void,
        stateReadAfterwards: Bool
    ) async {
        // A throw's writes matter only to a later destroy-phase handler that reads the state
        // (#87): no sync or record follows the destroy.
        let throwWriteKey = stateReadAfterwards ? name : nil
        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID
        )
        var updatedCtx = ctx
        do {
            if !resolvers.isEmpty {
                let resolverContext = ResolverContext(
                    landContext: ctx,
                    actionPayload: nil,
                    eventPayload: nil,
                    currentState: state
                )
                updatedCtx = try await ResolverExecutor.executeResolversWithoutDeadline(
                    executors: resolvers,
                    resolverContext: resolverContext,
                    landContext: ctx
                )
            }
            try withMutableStateSync(throwWriteKey: throwWriteKey) { state in
                try handler(&state, updatedCtx)
            }
        } catch {
            logger.error("❌ \(name) handler failed", metadata: [
                "error": .string(String(describing: error)),
            ])
        }
    }

    // Note: isEventAllowed is no longer needed as we use registry-based validation
}

/// Set-once flag readable from any isolation (`LandKeeper.isDraining`).
private final class DrainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var setCause: LandDestructionCause?

    var isSet: Bool { cause != nil }

    var cause: LandDestructionCause? {
        lock.lock()
        defer { lock.unlock() }
        return setCause
    }

    /// Sets the flag; the first cause stays.
    func set(cause: LandDestructionCause) {
        lock.lock()
        if setCause == nil { setCause = cause }
        lock.unlock()
    }
}

/// Why a land's destruction started (`LandKeeper.destructionCause`).
public enum LandDestructionCause: String, Codable, Sendable, Hashable {
    /// The land stayed empty for its `DestroyWhenEmpty` delay.
    case emptyTimeout
    /// `forceShutdown`: a server shutdown (`LandManager.shutdownAllLands`) or a test harness.
    case forceShutdown
    /// Its initialization failed (#104): torn down without the destroy handlers.
    case initializationFailed
}

private struct InternalPlayerSession: Sendable {
    var clientID: ClientID?
    var lastSessionID: SessionID?
    /// This entry's generation, new on every insert (`LandKeeper.entryGenerations`). Client and
    /// session IDs can repeat across joins of the same player, so work that awaits after
    /// reading the entry compares this instead: a failed OnJoin removes only its own join's
    /// entry (`discardIfFailedJoin`), and an action is delivered only to the entry it was sent
    /// to (`deliverResolvedAction`).
    var generation = Epoch(rawValue: 0)
    var services: LandServices
    // PlayerSession info (from join request)
    var deviceID: String?
    var isGuest: Bool
    var metadata: [String: String]

    init(services: LandServices, deviceID: String? = nil, isGuest: Bool = false, metadata: [String: String] = [:]) {
        clientID = nil
        lastSessionID = nil
        self.services = services
        self.deviceID = deviceID
        self.isGuest = isGuest
        self.metadata = metadata
    }
}

extension LandKeeper.PendingItem {
    /// The input's sequence number (shared counter across inputs and server events).
    var sequence: Int64 {
        switch self {
        case let .action(item): return item.sequence
        case let .clientEvent(item): return item.sequence
        case let .lifecycle(item): return item.sequence
        case let .serverInput(item): return item.sequence
        case let .shutdown(item): return item.sequence
        }
    }

    /// Whether this is the forced shutdown's input (#382).
    var isShutdown: Bool {
        if case .shutdown = self { return true }
        return false
    }

    /// The committed tick the input is bound to; it runs in the first tick after it.
    var resolvedAtTick: Int64 {
        switch self {
        case let .action(item): return item.resolvedAtTick
        case let .clientEvent(item): return item.resolvedAtTick
        case let .lifecycle(item): return item.resolvedAtTick
        case let .serverInput(item): return item.resolvedAtTick
        case let .shutdown(item): return item.resolvedAtTick
        }
    }
}
