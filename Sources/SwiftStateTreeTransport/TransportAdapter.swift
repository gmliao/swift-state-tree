import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack
import Logging
import SwiftStateTurns

/// Where a `TransportAdapter` awaits its test hold hook (`installHolds`).
enum TransportAdapterHoldPoint: Hashable, Sendable {
    /// An in-turn join (#69) after `keeper.joinReportingAdmission` returned with its admission,
    /// before the session is registered with the transport: admitted, its OnJoin may be
    /// consumed, but it can't flip yet. Taken only when the join completes in the turn.
    case keeperJoinReturned
    /// An in-turn join registered with the transport, before it asks the keeper for its sync
    /// turn (`requestJoinSyncTurn`), which can flip it (#555): registered, not yet flipped.
    case joinSyncRequested
    /// `admitJoin` on entry, before the join is queued on the membership queue (#97).
    case admitJoinEntry
    /// The delayed follow-up of a dropped initial sync (#564), before its `syncNow()`, so a test
    /// decides when that cycle runs instead of racing its 100 ms delay.
    case failedPlanFollowUp
    /// The debug freeze's auto-resume timer has fired, before it checks its generation, so a
    /// test decides when each timer acts instead of racing its timeout (#502).
    case debugFreezeAutoResumeFired
    /// A fired auto-resume timer that a newer freeze call or a resume replaced: it does nothing.
    case debugFreezeAutoResumeStale
    /// A pending action's answer (`finishActionResponse`), before it checks its ticket.
    case actionResponse
    /// A failure found outside a keeper turn (an answer or an event that didn't encode, a
    /// joiner's first sync that failed), after the output gate closed and the failure was noted
    /// on the keeper, before it is submitted (`submitNotedFailure`, #701, #704).
    case failureSubmit
    /// An in-turn freeze settle after its writer wait, before its keeper turn
    /// (`LandKeeper.settleTurn`): a release, refreeze, shutdown or expiry here is caught by the
    /// turn's fence (#546 L2d-1).
    case settleBeforeCommit
    /// An in-turn freeze settle after its keeper turn committed, before it checks its ticket
    /// and publishes: work that arrives here comes after the settle's copy (#546 L2b).
    case settleBeforePublish
    /// An in-turn resume after its deferred sync's request returned, before it checks for a
    /// refreeze and decides on the join-sync request (#546 L2b).
    case resumeAfterSync
    /// Before the initial sync reads the state.
    case initialSync
    /// After the initial sync read the state, before it checks its ticket and commits: the
    /// operation holds a state copy that a disconnect and rejoin can make stale (#98).
    case initialSyncAfterRead
    /// A flipped session's deferred-inbound drain, before it dispatches its next frame (#69).
    case inboundDrainDispatch
    /// The sync the lag timer requested (#332), before its `syncNow()`.
    case syncLagTimerSync
    /// A terminal lag close's Task (#332), before it asks the transport to close.
    case syncLagClose
    /// A terminal lag close's Task (#332), after the transport's close returned.
    case syncLagClosed
    /// A public `registerSession` (#531), after it read the keeper's entry and before it acts
    /// on what it read.
    case registrationAfterKeeperRead
    /// An operation in the membership queue, behind every earlier one, before it waits for them:
    /// the event that it is queued (#531).
    case membershipQueued
    /// A registration (#531), before it records the session's connection generation (and, with
    /// a `WebSocketTransport`, before that transport's await).
    case registrationGeneration
}

/// How the realtime adapter maps sessions to a player (#531). Both join paths read it: the
/// library's join (its admission) and `registerSession`. So the two can't drift onto different
/// rules. Package-level: no public policy API, and no other case until several sessions per
/// player are supported (#539).
package enum SessionPerPlayerPolicy: Sendable, Equatable {
    /// Newest wins: a newer session of the player replaces the older ones, which are logged out
    /// (superseded and closed), as in typical games.
    case replaceOld
}

/// `TransportAdapter.syncLagAckDiagnostics()`: a snapshot of one adapter's sync-lag ack state.
@_spi(Diagnostics) public struct SyncLagAckDiagnostics: Sendable, Equatable {
    /// Acks this adapter received and dropped since it was created: the session has ended, or it
    /// has no lag state (still joining, its firstSync not committed yet, or closing), or sync-lag
    /// tracking is off (no sync sequence). The last is counted only for an ack a router forwards:
    /// with tracking off, the adapter doesn't read its own inbound frames as acks. An ack is
    /// either form (`SyncAckFrame.parse`), whatever the session's message encoding. Not counted:
    /// an ack a router drops before it reaches the adapter (its session isn't bound to a live
    /// instance), and a frame that doesn't parse as an ack (it isn't one).
    public let droppedAcks: Int
    /// Tracked sessions with at least one committed state frame not yet acked, now.
    public let sessionsWithUnackedFrames: Int
}

/// Adapts Transport events to LandKeeper calls.
package actor TransportAdapter<State: StateNodeProtocol>: TransportDelegate {

    private let keeper: LandKeeper<State>

    /// How this adapter plans its syncs, for the record header (`ReevaluationSyncConfig`).
    public nonisolated var syncConfigForRecord: ReevaluationSyncConfig {
        ReevaluationSyncConfig(
            mergedBroadcastFrame: useStateUpdateWithEvents,
            fullSnapshot: syncStrategy == .fullSnapshot
        )
    }

    /// The encoding of the payload bytes a record of this adapter's land keeps, for the record
    /// header (`ReevaluationRecordMetadata.payloadEncoding`, #700 K1a): `messagepack` when the
    /// codec's frames are MessagePack, whose payloads decode through the MessagePack decoder, and
    /// `json` otherwise (`json` and `opcodeJsonArray` frames carry JSON payloads).
    public nonisolated var payloadEncodingForRecord: RecordPayloadEncoding {
        codec.encoding == .messagepack ? .messagepack : .json
    }

    /// The keeper's serial executor: the keeper can then call `runSyncPhaseInTurn` synchronously
    /// inside its own turn (`assumeIsolated`).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        keeper.unownedExecutor
    }

    /// Whether `keeper` is this adapter's keeper (identity).
    nonisolated func isAttached(to keeper: AnyObject) -> Bool {
        keeper === self.keeper
    }

    /// Tests only: runs `body` as a job on this adapter's executor.
    func runIsolatedForTesting(_ body: @Sendable () -> Void) {
        body()
    }

    /// Tests only: forces the in-turn back-pressure check on (in addition to the real one).
    private var writerBackPressureOverrideForTesting: (@Sendable () -> Bool)?

    /// Installs `writerBackPressureOverrideForTesting` (tests only).
    func setWriterBackPressureOverrideForTesting(_ override: (@Sendable () -> Bool)?) {
        writerBackPressureOverrideForTesting = override
    }

    /// Forced-interleaving hold points (tests only; a no-op unless installed).
    private var holds = HoldPoints<TransportAdapterHoldPoint>()

    /// Installs (or, with `nil`, removes) the hold hook for every `TransportAdapterHoldPoint`
    /// (tests).
    func installHolds(_ hook: (@Sendable (TransportAdapterHoldPoint) async -> Void)?) {
        holds.install(hook)
    }

    /// Whether a test forces the in-turn back-pressure check on.
    func writerBackPressureForcedForTesting() -> Bool {
        writerBackPressureOverrideForTesting?() ?? false
    }

    /// The back-pressure rule for in-turn sync phases: the writer still holds a sync cycle
    /// element from an earlier phase (`hasPendingStateElement`). Event elements are
    /// not counted, so the turn's own event frames never trigger it.
    private func writerHoldsEarlierElementForInTurnSync() -> Bool {
        hasPendingStateElement || (writerBackPressureOverrideForTesting?() ?? false)
    }
    let transport: any Transport
    /// Ordered FIFO for every frame this adapter sends (#60). See `OutboundWriter`.
    let outboundWriter: OutboundWriter
    /// Transport connection generation per joined session, stamped on every frame so the
    /// transport drops frames for an ended connection. Read when the connection was accepted
    /// (`LandRouter` passes it to `performJoin`), else when the session registers.
    ///
    /// Defence in depth: `NIOWebSocketServer` gives every connection a fresh `UUID` SessionID, so
    /// this matters only for transports or tests that reuse SessionIDs.
    var connectionGenerations: [SessionID: UInt64] = [:]
    /// Sessions that ended (disconnected, or disconnected by the server after a writer ceiling
    /// drop). Frames for them are dropped before the writer, also unstamped ones.
    var endedSessions = EndedSessionSet()

    /// Closed once when the land fails (#535): no new state or event frame is enqueued after it.
    /// Lock-protected and set once, so the keeper closes it from its own isolation without an
    /// await, and every send point reads it in the segment that enqueues. Best effort against a
    /// close from another executor: the read and the enqueue aren't one atomic step, so a frame
    /// whose check passed just before the close still goes out; none is enqueued after.
    package nonisolated let outputGate = LandOutputGate()

    /// Tests only: replaces `endedSessions` with an empty set of `capacity`.
    func setEndedSessionCapacityForTesting(_ capacity: Int) {
        endedSessions = EndedSessionSet(capacity: capacity)
    }
    /// The router join attempt (`LandRouter`'s attempt number, #97) each member session joined
    /// with. An attempt older than the one its player's member session came from isn't admitted
    /// (`staleJoinAttempt`).
    var memberJoinAttempts: [SessionID: UInt64] = [:]
    /// Sessions the server disconnected after a writer ceiling drop.
    var outboundCeilingDisconnects = 0
    /// The no-op-`closeSession` warning was logged (once per adapter).
    var warnedNoCloseSession = false
    /// Sync phases skipped before they plan (see `SyncSkipCounts`).
    var syncSkips = SyncSkipCounts()
    /// Sync Tasks this adapter started in the background (the delayed repair, the lag timer's
    /// request), by id, until they finish: `waitForBackgroundSyncsForTesting` awaits them.
    var backgroundSyncTasks: [UInt64: Task<Void, Never>] = [:]
    var nextBackgroundSyncTaskID: UInt64 = 0
    /// `landID` for the outbound extension's logs.
    var landIDForOutbound: String { landID }
    /// Logger for the outbound extension.
    var outboundLogger: Logger { logger }

    /// Holds every in-turn join before its flip while set (tests only): the sync phase plans and
    /// commits without them, so a join stays admitted and unflipped without a plan that throws
    /// (a throw ends the land since #535).
    func setJoinFlipHeldForTesting(_ held: Bool) {
        joinFlipHeldForTesting = held
    }

    /// Installs `syncPlanFaultForTesting` (tests only).
    func setSyncPlanFaultForTesting(_ fault: (@Sendable () throws -> Void)?) {
        syncPlanFaultForTesting = fault
    }

    /// Sets the optional detail on recorded sync outputs, in place of the environment's.
    func setSyncStreamDetail(_ detail: SyncStreamRecordingDetail) {
        syncStreamDetail = detail
    }

    /// Which encodings of an event fail (tests only).
    enum EventEncodingFault: Sendable {
        /// Every encoding: the event is lost.
        case all
    }


    /// Makes every action's error reply fail to encode while set (tests only, #691).
    func setErrorReplyEncodingFaultForTesting(_ fault: Bool) {
        errorReplyEncodingFaultForTesting = fault
    }

    /// Installs `eventEncodingFaultForTesting` (tests only).
    func setEventEncodingFaultForTesting(_ fault: (@Sendable (String) -> EventEncodingFault?)?) {
        eventEncodingFaultForTesting = fault
    }

    /// Installs `syncOutputDigestFaultForTesting` (tests only).
    func setSyncOutputDigestFaultForTesting(_ fault: (@Sendable (inout SyncOutputDigestInput) -> Void)?) {
        syncOutputDigestFaultForTesting = fault
    }

    /// Whether the next committed full plan resets the key scopes (tests and diagnostics).
    func isKeyScopeResetPending() -> Bool {
        keyScopeResetPending
    }

    /// Tests only: whether dirty tracking is on now.
    func dirtyTrackingEnabledForTesting() -> Bool {
        enableDirtyTracking
    }

    /// Whether `sessionID` has a current session ticket (tests).
    func hasSessionTicketForTesting(_ sessionID: SessionID) -> Bool {
        sessionTickets.ticket(for: sessionID) != nil
    }

    /// Dirty fields of failed plans, merged into the next plan's (tests).
    func carriedDirtyFieldsForTesting() -> Set<String> {
        carriedDirtyFields
    }

    /// The broadcast diff runs on the sync tables.
    func usesSyncTablesForTesting() -> Bool {
        broadcastTables != nil
    }

    /// Sync plans that extracted per-player snapshots (tests): none with the per-player tables,
    /// which read the fields they diff themselves (#514).
    private(set) var perPlayerExtractionsForTesting = 0

    /// Per-player fields are diffed on the per-player tables (#514).
    func usesPerPlayerTablesForTesting() -> Bool {
        perPlayerTables != nil
    }

    /// Whether the per-player tables are in effect (#514): the broadcast tables are, and
    /// `PER_PLAYER_SYNC_TABLES` is on. For diagnostics and equivalence tests outside this package.
    @_spi(Diagnostics) public func perPlayerSyncTablesInEffect() -> Bool {
        perPlayerTables != nil
    }

    /// What `playerID`'s client was last sent for the per-player fields (tests): the per-player
    /// tables' committed boxes when they are in effect, the engine's per-player cache otherwise.
    func lastSentPerPlayerSnapshotForTesting(_ playerID: PlayerID) -> StateSnapshot? {
        perPlayerTables.map { $0.lastSentSnapshot(for: playerID) } ?? syncEngine.cachedPerPlayerSnapshotForTesting(playerID)
    }

    /// The sync tables convert leaf fields by their typed form (`TYPED_LEAF_VALUES`).
    func usesTypedLeafValuesForTesting() -> Bool {
        broadcastTables?.typedLeafValues ?? false
    }

    /// The slot and generation of each row of the root field `name` by key string, in the tables.
    func rowSlotsForTesting(_ name: String) -> [String: SyncRowSlotForTesting]? {
        broadcastTables?.rowSlotsForTesting(name)
    }

    /// The sync engine's caches (tests).
    func syncEngineForTesting() -> SyncEngine {
        syncEngine
    }

    /// How the typed tables diff each broadcast root field (a typed kind, or `.fallback` for
    /// today's snapshot diff), or nil when the broadcast diff doesn't run on the tables. For
    /// diagnostics and equivalence tests only, with no stability promise: a field that takes the
    /// fallback gains nothing from the tables.
    @_spi(Diagnostics) public func syncTableFieldKinds() -> [String: SyncTableFieldKind]? {
        broadcastTables?.kinds
    }

    /// How the per-player tables (#514) diff each per-player root field, or nil when they aren't
    /// in effect. Diagnostics and equivalence tests only, as `syncTableFieldKinds()`: a field on
    /// `.fallback` gains nothing from the tables.
    @_spi(Diagnostics) public func perPlayerSyncTableFieldKinds() -> [String: SyncTableFieldKind]? {
        perPlayerTables?.kinds
    }

    /// What clients were last sent for the broadcast fields (tests): the typed tables as a
    /// snapshot when the broadcast diff runs on them, the engine's broadcast cache otherwise.
    func lastSentBroadcastSnapshotForTesting() -> StateSnapshot? {
        broadcastTables.map(\.lastSentSnapshot) ?? syncEngine.cachedBroadcastSnapshotForTesting
    }

    /// Installs `syncEncodeFaultForTesting` (tests only).
    func setSyncEncodeFaultForTesting(_ fault: (@Sendable (PlayerID) -> Bool)?) {
        syncEncodeFaultForTesting = fault
    }

    /// Installs `eventFramePackFaultForTesting` (tests only).
    package func setEventFramePackFaultForTesting(_ fault: (@Sendable (SessionID) -> Bool)?) {
        eventFramePackFaultForTesting = fault
    }

    /// Installs `mergedBroadcastFrameFaultForTesting` (tests only).
    func setMergedBroadcastFrameFaultForTesting(_ fault: (@Sendable () -> Bool)?) {
        mergedBroadcastFrameFaultForTesting = fault
    }

    /// Installs `mergedEventsPackFaultForTesting` (tests only).
    func setMergedEventsPackFaultForTesting(_ fault: (@Sendable () -> Bool)?) {
        mergedEventsPackFaultForTesting = fault
    }

    /// How long teardown waits for queued frames to reach the transport.
    static var outboundTeardownTimeout: Duration { .seconds(2) }
    private let landID: String
    private let codec: any TransportCodec
    private let messageEncoder: any TransportMessageEncoder
    /// `messageEncoder`'s reply encode from the keeper's outcome (#700 K1a), when it has one: an
    /// action's response reaches the frame without being boxed into `AnyCodable`. Cast once here,
    /// not per reply.
    private let actionResponseEncoder: (any ActionResponseFrameEncoder)?
    /// Replies sent through the boxed fallback, because `messageEncoder` has no outcome entry
    /// (tests only: every built-in encoder has one, so this stays 0, and a lost cast shows).
    package private(set) var boxedActionResponsesForTesting = 0
    private let stateUpdateEncoder: any StateUpdateEncoder
    /// Sync-lag tracking (#332): on with the encoding's `syncSequence`, which also makes the
    /// feature required at join.
    private let tracksSyncLag: Bool
    /// The last sync sequence a plan took (#332). Per land, increasing; a plan that doesn't
    /// commit leaves a gap.
    private var lastSyncSeq: UInt64 = 0
    /// Mirrors of the plan being built's `syncSeq` and `syncLag.resyncPlayers`, read by the
    /// state-update encodes (which don't take the plan). Read only between `makePlan` and the
    /// encodes, in one synchronous segment; cleared when `runSyncPhase` returns.
    private var planSyncSeq: UInt64?
    private var planResyncPlayers: Set<PlayerID> = []
    /// The thresholds of the lag decisions (#332).
    /// The sync-lag thresholds (#332): the environment's, unless the host sets its own before
    /// any session joins (`setSyncLagPolicy`).
    private var syncLagPolicy: SyncLagPolicy = .fromEnvironment()
    /// Each tracked session's lag state, from its firstSync's commit until the session ends.
    private var syncLag: [SessionID: SyncLagSession] = [:]
    /// The lag clock; tests replace it.
    package var syncLagNowForTesting: (@Sendable () -> ContinuousClock.Instant)?
    /// Counters (#332).
    package private(set) var syncLagResyncs = 0
    /// Other sessions of a resynced player that got its snapshot.
    package private(set) var syncLagResyncsAlongside = 0
    package private(set) var syncLagPendingMarks = 0
    package private(set) var syncLagKeyScopeResets = 0
    package private(set) var syncLagKeyScopeResetBytes = 0
    package private(set) var syncLagSlowConsumerCloses = 0
    package private(set) var syncLagUnresponsiveCloses = 0
    package private(set) var syncLagDroppedAcks = 0
    package private(set) var syncLagDroppedEvents = 0
    /// The lag timer (#332): runs while a session is tracked. Read-only: it closes what is due
    /// and requests a sync on a land without periodic sync; the plan does the rest.
    private var syncLagTimer: Task<Void, Never>?
    private var syncLagTimerEpoch: UInt64 = 0
    /// The epoch of the timer pass whose requested sync hasn't run yet (one per epoch).
    private var syncLagTimerSyncRequestedEpoch: UInt64?
    package private(set) var syncLagTimerSyncRequests = 0
    /// The timer's period; tests shorten it.
    package var syncLagTimerInterval: Duration = .milliseconds(250)
    private let pathHashes: [String: UInt32]?
    private var syncEngine = SyncEngine(for: State.self)
    /// The broadcast diff on the typed tables (`TransportEnvConfig.useSyncTables`, delta strategy
    /// only), or nil: today's snapshot diff. With it, the sync path never reads the engine's
    /// broadcast cache (`SyncEngine.broadcastCacheRetired`); per-player fields stay on the engine.
    private let broadcastTables: SyncTableBroadcastDiff<State>?
    /// The per-player diff on typed per-player tables (#514): in effect where the broadcast
    /// tables are, unless `PER_PLAYER_SYNC_TABLES` is off. With it, the sync path never reads the
    /// engine's per-player cache (`SyncEngine.perPlayerCacheRetired`).
    private let perPlayerTables: SyncTablePerPlayerDiff<State>?
    private let logger: Logger
    private let enableLegacyJoin: Bool
    
    /// Message decoding pipeline (centralizes all decoding logic).
    private let decodingPipeline: MessageDecodingPipeline
    
    /// Message routing table (centralizes all routing logic).
    private let routingTable: MessageRoutingTable
    
    /// Encoding pipeline (centralizes all encoding logic).
    private let encodingPipeline: EncodingPipeline
    
    /// Event sending pipeline (centralizes event sending logic: queue vs immediate).
    private let eventSendingPipeline: EventSendingPipeline

    /// Dirty tracking toggle - default is enabled.
    ///
    /// When disabled, sync will:
    /// - Always use `.all` snapshot mode (no dirty-field filtering)
    /// - Skip the sync phase's `clearDirty()` to avoid recursive reset cost
    ///
    /// Performance: With high update ratio (most fields changing every frame), disabling dirty tracking may be faster.
    /// With low-to-medium update ratio (typical game usage), keep it enabled to save serialization and diff cost.
    private var enableDirtyTracking: Bool
    
    /// When true, use one-pass extraction (state.snapshotForSync) instead of separate broadcast + per-player extractions.
    /// Default is true; set USE_SNAPSHOT_FOR_SYNC=false to use the legacy path.
    private let useSnapshotForSync: Bool

    /// Sync strategy: `.delta` (dirty-field diffing, default) or `.fullSnapshot` (always send the full view).
    /// Overridable at runtime via `SYNC_STRATEGY`.
    private let syncStrategy: SyncStrategy



    /// Expected schema hash for version verification.
    /// If set, clients must provide matching schemaHash in join metadata.
    private var expectedSchemaHash: String?

    /// The state-update features this adapter's frames use (`TransportEncodingConfig
    /// .stateUpdateFeatures`): a join must declare each in its metadata's `stateUpdateFeatures`,
    /// and `joinResponse` echoes them.
    package nonisolated let stateUpdateFeatures: [String]

    /// `stateUpdateFeatures`, for a tool outside the package that records what a land had in
    /// effect (a benchmark): the list this land's `joinResponse` echoes, `rowAddressing`
    /// included only where it is in effect.
    @_spi(Diagnostics) public nonisolated var effectiveStateUpdateFeatures: [String] {
        stateUpdateFeatures
    }

    /// Row entries (`TransportEncodingConfig.rowAddressing`) are in effect: requested, with
    /// their required features, in-turn sync and joins through the router. Fixed at init.
    package nonisolated let rowAddressing: Bool

    /// Patches dropped because their path has no schema pattern (with `pathIndex` on; see
    /// `UnmappedPathCounter`). Each new pattern is logged once.
    private let unmappedPathCounter: UnmappedPathCounter

    /// The number of patches dropped for a path outside the schema (`unmappedPathCounter`): the
    /// rest of each update was sent without them.
    public var unmappedPathPatches: Int { unmappedPathCounter.droppedPatches }

    /// Membership coordinator (centralizes all membership management).
    private let membershipCoordinator: MembershipCoordinator
    
    /// Players in their initial sync, each with the session ticket whose initial sync set the
    /// mark (`nil` from `beginInitialSync(for:)`). Only that initial sync removes it: when a
    /// newer session of the player (newest wins) starts its initial sync while an older one is
    /// still finishing, the older one must not clear the newer one's mark.
    private var initialSyncingPlayers: [PlayerID: Ticket<SessionID>?] = [:]

    /// One generation per admitted session: issued in the admission segment (`admitJoining`),
    /// ended when the session disconnects, is superseded or its join is abandoned. Work that
    /// awaits after the admission (the initial sync) captures the ticket and acts only while it
    /// is current, so it never acts for a session that ended meanwhile, also when a later
    /// connection reuses the SessionID.
    private var sessionTickets = GenerationTable<SessionID>()
    /// Per session, the tasks that answer its pending action jobs (an action with resolvers on
    /// a tick land), keyed by the job's sequence. A disconnect cancels and drops them.
    private var actionResponseTasks: [SessionID: [Int64: Task<Void, Never>]] = [:]
    /// A session's ticket for its action response tasks, ended on disconnect: a job submitted
    /// before the disconnect but returned after it gets no tracked task and no response.
    private var actionResponseTickets = GenerationTable<SessionID>()
    /// Tests only: pending answers finished (sent or dropped), and the waiters for a count.
    private var actionResponsesFinished = 0
    private var actionResponsesFinishedWaiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextActionResponsesFinishedWaiter = 0

    /// A session admitted by a join (#69) whose initial sync hasn't started yet.
    struct JoiningSession: Sendable {
        let playerID: PlayerID
        let playerSlot: Int32
        let ticket: Ticket<SessionID>
        /// Set when the join completes in a turn (in-turn path with a JoinResponse builder):
        /// the session flips to joined in the commit of a full sync phase.
        var inTurn: InTurnJoin?
        /// Targeted events held for an in-turn join until its flip (#69), as encoded event
        /// frames in arrival order. The flip sends them after its firstSync; a join that ends
        /// without a flip discards them.
        var heldEvents: [EncodedFrame] = []
        /// Encoded bytes of `heldEvents`.
        var heldBytes = 0
        /// Inbound frames from the session while its in-turn join waits for its flip (#69), in
        /// arrival order: applied after the flip (`inboundAfterFlip`), dropped if the join fails.
        var deferredInbound: [Data] = []
        /// Bytes of `deferredInbound`.
        var deferredInboundBytes = 0
    }

    /// A flipped session's deferred inbound frames, applied one at a time by its drain
    /// (`drainInbound`) (#69). While the entry exists, new frames of the session are appended
    /// here instead of dispatched, so none overtakes the deferred ones; it is removed only in
    /// the segment that finds the queue empty after a dispatch.
    struct InboundDrain: Sendable {
        let ticket: Ticket<SessionID>
        var frames: [Data]
        var bytes: Int
    }

    /// Drains of flipped sessions' deferred inbound frames (#69).
    var inboundAfterFlip: [SessionID: InboundDrain] = [:]
    /// Sessions closed for an inbound overflow after their flip, until their disconnect: their
    /// later frames are dropped and counted, never dispatched (#69). The close only ends the
    /// outbound side, and its disconnect can take up to the final-frame timeout to arrive.
    private var inboundClosedSessions: Set<SessionID> = []
    /// Inbound frames deferred while their session's join waited for its flip (#69).
    private(set) var inboundDeferredForJoiningSessions = 0
    /// Deferred inbound frames dropped: their join failed, or their session ended first (#69).
    /// Inbound frames dropped for a session whose inbound is closed: a join that failed or was
    /// superseded, a drain that stopped, or a lag close (#332). The name predates the last ones.
    private(set) var inboundDroppedForJoiningSessions = 0
    /// Sessions closed because their inbound queue went over the bound after their flip (#69).
    private(set) var inboundOverflowClosures = 0
    /// Test override of the deferred-inbound bound (`JoinFlipConfig.deferredInboundMax(Bytes)`).
    private var deferredInboundLimitOverride: (count: Int, bytes: Int)?

    /// Frames waiting in the session's drain after its flip (tests).
    func inboundAfterFlipCount(_ sessionID: SessionID) -> Int? {
        inboundAfterFlip[sessionID]?.frames.count
    }

    #if DEBUG
    /// Debug only: the last drain started for each session, so a test can await its end.
    private var inboundDrainTasksForTesting: [SessionID: Task<Void, Never>] = [:]
    #endif

    /// Tests only: returns once the session's last started drain has ended (it dispatched every
    /// frame it held, or the session ended). Returns at once in release builds.
    func waitForInboundDrainForTesting(_ sessionID: SessionID) async {
        #if DEBUG
        await inboundDrainTasksForTesting[sessionID]?.value
        #endif
    }

    func setDeferredInboundLimitForTesting(count: Int, bytes: Int) {
        deferredInboundLimitOverride = (count, bytes)
    }

    private var deferredInboundLimit: (count: Int, bytes: Int) {
        deferredInboundLimitOverride ?? (JoinFlipConfig.deferredInboundMax, JoinFlipConfig.deferredInboundMaxBytes)
    }

    /// A join that completes in a turn (#69): its JoinResponse and firstSync are frames of the
    /// first committed full sync phase after it is ready (`isReadyToFlip`).
    struct InTurnJoin: Sendable {
        /// The OnJoin input's sequence; nil when the join has none.
        let joinSequence: Int64?
        /// Admission order: ready joins flip first in, first out.
        let order: UInt64
        /// The JSON JoinResponse frame, built in the admission segment.
        let joinResponse: Data
        /// A turn applied the OnJoin input (or the join has none).
        var consumed: Bool
        /// The session is registered with the transport (`registerSession` returned).
        var transportRegistered = false
        /// The join failed (its waiter got the reason); it never flips. The session stays
        /// excluded until its disconnect removes the record.
        var failed = false
        /// The router attempt's mailbox, marked when the join flips (#867); nil for a join
        /// admitted without a router attempt.
        var attemptEnd: JoinAttemptEnd?

        var isReadyToFlip: Bool { consumed && transportRegistered && !failed }
        /// Ready, and asking for a sync turn of its own (`hasJoinsAwaitingSync`).
        var isAwaitingJoinSync: Bool { isReadyToFlip }
    }

    /// The waiter of a join that completes in a turn (`awaitJoined`), created at admission. The
    /// flip or a failure resolves it; it may resolve before the join's caller awaits it.
    final class JoinWaiter {
        let ticket: Ticket<SessionID>
        var result: Result<Void, JoinFlipError>?
        var continuation: CheckedContinuation<Void, any Error>?
        var timeout: Task<Void, Never>?

        init(ticket: Ticket<SessionID>) {
            self.ticket = ticket
        }

        func resolve(_ outcome: Result<Void, JoinFlipError>) {
            guard result == nil else { return }
            result = outcome
            timeout?.cancel()
            timeout = nil
            if let continuation {
                self.continuation = nil
                continuation.resume(with: outcome.mapError { $0 as any Error })
            }
        }
    }

    /// Waiters of joins that complete in a turn, by session (`awaitJoined` removes them).
    private var joinWaiters: [SessionID: JoinWaiter] = [:]
    /// Next admission order of an in-turn join.
    private var nextInTurnJoinOrder: UInt64 = 0
    /// Joins flipped in a committed sync phase so far, and failures by reason (diagnostics).
    private(set) var inTurnJoinFlips = 0
    /// Targeted events (`.session`, `.client`, `.player`, `.players`) addressed to a joining
    /// session and not delivered to it: those discarded with an in-turn join that failed (its
    /// held events, and on `eventOverflow` the overflowing one), and on the path without an
    /// in-turn join every one addressed to a joining session. 0 in a run where every in-turn
    /// join succeeds. Counted, with a rate-limited debug log, so the gap is visible.
    private(set) var eventsDroppedForJoiningSessions = 0
    /// Initial syncs dropped after their state read because the session's ticket ended or its
    /// membership changed during the read (#98): nothing was committed for them (diagnostics).
    private(set) var initialSyncsDroppedStale = 0
    /// Initial syncs dropped after their state read because a sync phase committed during the
    /// read (#564): the shared broadcast cache may already be past the read, so the next cycle
    /// sends the player its whole view instead (diagnostics).
    private(set) var initialSyncsDroppedBehindCommit = 0
    /// Initial syncs dropped after their state read because the land failed during the read
    /// (#535): the output gate is closed, so nothing was planned, committed or recorded for
    /// them (diagnostics).
    private(set) var initialSyncsDroppedLandFailed = 0
    /// Frames dropped at the writer's door because the land's output gate was closed (#696): an
    /// action's answer, an error or join reply, or a router frame after the land failed.
    package internal(set) var framesDroppedLandFailed = 0
    /// Counts sync phase commits. A standalone firstSync captures it before its state read and
    /// commits only if it is unchanged after (#564): a commit in between may have moved the
    /// shared broadcast cache past the read, which the next diff would then start from.
    private var syncPhaseCommits: UInt64 = 0
    /// Targeted events held for an in-turn join and sent after its firstSync at its flip (#69).
    private(set) var eventsHeldForJoiningSessions = 0
    /// In-turn joins whose held events went over the bound in a target resolution
    /// (`sessionIDs(for:holding:)`); they fail with `eventOverflow` after the emit returns.
    private var heldEventOverflows: [SessionID] = []
    /// Tests only: replaces `JoinFlipConfig.heldEventsMax` / `heldEventsMaxBytes`.
    private var heldEventsLimitForTesting: (count: Int, bytes: Int)?
    private var lastJoiningEventDropLog: ContinuousClock.Instant?
    private(set) var inTurnJoinFailures: [JoinFlipError: Int] = [:]

    /// Tests only: replaces the flip wait (what is left of the join budget, #104) for joins
    /// admitted from now on. `.zero`: no flip timeout.
    private var joinFlipTimeoutForTesting: Duration?
    /// Tests only: replaces `JoinFlipConfig.budget`.
    private var joinFlipBudgetForTesting: Int?

    /// Tests only: see `joinFlipTimeoutForTesting` and `joinFlipBudgetForTesting`.
    func setJoinFlipLimitsForTesting(timeout: Duration?, budget: Int?) {
        joinFlipTimeoutForTesting = timeout
        joinFlipBudgetForTesting = budget
    }

    /// Sessions admitted by a join and not yet in their initial sync (`.joining`). Recorded in
    /// the admission segment (`admitJoining`), together with the membership and the player
    /// slot, and handed over to `initialSyncingPlayers` when the initial sync starts. A joining
    /// session is not a sync recipient and not reached by `.player` or `.broadcast` frames (it
    /// still gets frames addressed to it, such as its JoinResponse), so it can't get a diff or an
    /// event before its JoinResponse and firstSync.
    private var joiningSessions: [SessionID: JoiningSession] = [:]
    /// The lifecycle log and this land instance's number in it (`LandManager` attaches them
    /// when the log is on): a completed join writes `sessionJoined`.
    private var lifecycleLog: LandLifecycleLog?
    private var lifecycleInstance: UInt64?

    /// Attaches the lifecycle log, before the land is published (`LandManager.buildLand`).
    func attachLifecycleLog(_ log: LandLifecycleLog, instance: UInt64) {
        lifecycleLog = log
        lifecycleInstance = instance
    }

    /// A join completed: called in the segment that ends the session's joining, where its
    /// player mapping is current.
    private func noteSessionJoined(_ sessionID: SessionID, playerID: PlayerID) {
        lifecycleLog?.logSessionJoined(sessionID: sessionID, playerID: playerID, landID: landID, instance: lifecycleInstance)
    }

    /// Joins in `performJoinQueued` waiting for the keeper's in-turn admission callback, with
    /// what the admission needs that the keeper doesn't pass.
    private var expectedAdmissions: [SessionID: ExpectedAdmission] = [:]

    struct ExpectedAdmission {
        let authInfo: AuthenticatedInfo?
        /// Builds the JSON JoinResponse from the final playerID and slot. With it, an in-turn
        /// admission completes the join in a turn (`InTurnJoin`).
        let joinResponse: (@Sendable (PlayerID, Int32) -> Data?)?
        /// When the join's budget runs out (#104): the flip waits for what is left of it.
        let joinDeadline: ContinuousClock.Instant?
        /// The router's join attempt, for the stale check by the resolved player (#234).
        let joinAttempt: UInt64?
        /// The router attempt's mailbox, handed to the in-turn join for its flip (#867).
        let attemptEnd: JoinAttemptEnd?
    }

    /// Admissions made by the keeper's in-turn callback (tests only).
    private(set) var inTurnAdmissionCountForTesting = 0

    /// Set when a sync plan failed (its encodes may have allocated key slots in the encoders'
    /// dynamic key tables that no client learned, the frames were never sent).
    ///
    /// The next committed full plan types every recipient's update `.firstSync`, even when empty:
    /// the encoders reset the scope's key table and the client clears its key map for that scope,
    /// then the frame defines every key it uses. Its patches are the plan's normal diff against
    /// the cache (dirty-only with dirty tracking); clients apply a firstSync's patches onto their
    /// view like a diff. Cleared by that commit (one with at least one recipient).
    ///
    /// Limit: the reset covers the plan's recipients only. A player in initial sync
    /// (`initialSyncingPlayers`) is not one, so its broadcast key map is not reset by that commit;
    /// its per-player scope is reset by its own firstSync, and the broadcast scope of joiners is
    /// #90's.
    private var keyScopeResetPending = false
    /// Whether the shared broadcast key table may hold slots: a committed merged broadcast frame
    /// carried state patches since the last key scope reset. Until then a joiner's firstSync
    /// needs no reset (#90), so the first player of a land gets plain diffs.
    /// Conservative: a plan that fails after encoding leaves it unchanged, and a failed plan
    /// requests a reset anyway.
    private var broadcastKeysMayBeDefined = false

    /// Dirty fields of full plans that failed: their phase cleared the flags, but nothing was
    /// committed. Merged into every plan's dirty fields (`planDirtyFields(of:)`) until a full
    /// plan commits, so a failed plan loses no change.
    private var carriedDirtyFields: Set<String> = []

    /// Where the plan being run read its state, set for one plan + commit (`runSyncPhase`) when
    /// the keeper records its sync stream; nil otherwise, and then no plan fills a digest.
    private var syncOutputRead: SyncOutputRead?
    /// Players seeded in the sync stream so far: a later seed is a rejoin. Never pruned (a
    /// leave keeps the player, so its next seed is a rejoin); it grows by one entry per distinct
    /// player over the adapter's life, only while the sync stream is recorded.
    private var syncStreamSeededPlayers: Set<PlayerID> = []
    /// Players whose latest seed was not verifiable (`viewDrops` not empty), until a verifiable
    /// seed or a clear: left out of `perPlayerHash` (`perPlayerUnverified`).
    private var syncStreamUnverifiedPlayers: Set<PlayerID> = []
    /// Players with a view in the sync stream: seeded, and not cleared since. One whose sessions
    /// have all ended before its clear (a leave's turn runs before the clear, #553) isn't
    /// addressed by an output in between: that output lists it in `perPlayerUnverified`.
    private var syncStreamViewPlayers: Set<PlayerID> = []
    /// Opcode 107: sequences of in-turn events with no recipient, until the next recorded output
    /// lists them (`eventsNotQueued`).
    private var syncStreamUnqueuedEvents: [Int64] = []
    /// Opcode 107: sequences of in-turn events that had recipients but were not merged (sent
    /// alone, or lost), until the next recorded output lists them (`eventsNotMerged`).
    private var syncStreamUnmergedEvents = ReevaluationUnmergedEvents()
    /// Tests only: plans that filled a `SyncOutputDigestInput`.
    private(set) var syncOutputDigestCountForTesting = 0

    /// Delay of the follow-up after a dropped initial sync (#564) on a land without periodic sync.
    static var syncFailedPlanFollowUpDelay: Duration { .milliseconds(100) }


    /// Tests only: per-player state updates of a player for which this returns `true` fail to
    /// encode (any update type, any encoding).
    private var syncEncodeFaultForTesting: (@Sendable (PlayerID) -> Bool)?
    /// Tests only: while this returns `true`, the opcode 107 merged broadcast frame fails to
    /// encode.
    private var mergedBroadcastFrameFaultForTesting: (@Sendable () -> Bool)?
    /// Tests only: while this returns `true`, merging the broadcast events into the opcode 107
    /// frame fails, as a pack failure would (#535 row 17).
    private var mergedEventsPackFaultForTesting: (@Sendable () -> Bool)?
    /// Fails the pack of an opcode 103 event frame for a session (tests only, #535 row 17).
    private var eventFramePackFaultForTesting: (@Sendable (SessionID) -> Bool)?
    /// The phase times of the last committed full plan; nil while profiling is off.
    private(set) var lastSyncPhaseTimesForTesting: SyncPhaseTimes?

    /// Sync plans that failed (threw) since the adapter started (diagnostics).
    private(set) var syncFailedPlans = 0

    /// When the last "sync plan failed" error was logged (rate limit).
    private var lastSyncFailureLog: ContinuousClock.Instant?

    /// Tests only: called at the end of every sync plan, after its diffs were staged and its
    /// frames encoded. A throw fails the plan there.
    private var syncPlanFaultForTesting: (@Sendable () throws -> Void)?
    /// `setJoinFlipHeldForTesting`.
    private var joinFlipHeldForTesting = false
    /// Thrown by a joiner's firstSync plan (`planFirstSync`) when set (tests only).
    private var firstSyncPlanFaultForTesting: (@Sendable () throws -> Void)?

    /// Sets the sync-lag thresholds (the host, before any session joins). Tracking runs only
    /// with an encoding that carries the sync sequence (`TransportEncodingConfig.syncSequence`).
    package func setSyncLagPolicy(_ policy: SyncLagPolicy) {
        syncLagPolicy = policy
    }

    /// The sync-lag policy in effect (tests).
    func syncLagPolicyForTesting() -> SyncLagPolicy { syncLagPolicy }

    /// The ack side of sync-lag tracking, for a tool outside the package that acks as a client
    /// (a benchmark): whether its acks were taken. See `SyncLagAckDiagnostics`.
    @_spi(Diagnostics) public func syncLagAckDiagnostics() -> SyncLagAckDiagnostics {
        SyncLagAckDiagnostics(
            droppedAcks: syncLagDroppedAcks,
            sessionsWithUnackedFrames: syncLag.values.filter { $0.unackedCount > 0 }.count
        )
    }

    package func setFirstSyncPlanFaultForTesting(_ fault: (@Sendable () throws -> Void)?) {
        firstSyncPlanFaultForTesting = fault
    }

    /// Tests only: rewrites a committed plan's digest before it is hashed, standing in for a
    /// diff that sent something else (the sync-output verifier must report it).
    private var syncOutputDigestFaultForTesting: (@Sendable (inout SyncOutputDigestInput) -> Void)?
    /// Optional detail on recorded sync outputs (`REEVALUATION_RECORD_SYNC_DETAILS`,
    /// `REEVALUATION_RECORD_SYNC_PATCHES`).
    private var syncStreamDetail = SyncStreamRecordingDetail.fromEnvironment()
    /// Tests only: makes an event's encoding fail, by event type.
    private var eventEncodingFaultForTesting: (@Sendable (String) -> EventEncodingFault?)?
    /// Tests only: makes an action's error reply fail to encode (#691).
    private var errorReplyEncodingFaultForTesting = false

    /// Membership queue prevents stale join/leave work from delivering after rejoin.
    /// See Notes/plans/2026-02-01-membership-queue-reconnect.md.
    private var membershipQueueTail: Task<Void, Never>?

    /// Manager for pending server events (targeted and broadcast).
    /// Encoded once when queued to avoid per-session re-encoding. Cleared after each sync.
    private var pendingEventManager = PendingEventManager()

    /// Debug freeze bookkeeping (see `TransportAdapter+DebugFreeze.swift`).
    var debugFreezeState = DebugFreezeState<State>()
    /// One generation per freeze: issued when a freeze starts from zero references, ended when
    /// it is released. A settle captures its ticket before its first await and acts only while
    /// it is current, so a settle of a released freeze never publishes over, or clears, a newer
    /// freeze's state (#546 L2d-1).
    var debugFreezeTickets = GenerationTable<DebugFreezeKey>()

    /// Whether to merge server events with state update (opcode 107): the state update encoding
    /// is `opcodeMessagePack`. Decided once at init (#521 D10): `StateUpdateEncoder.encoding` is a
    /// protocol getter, and the record header (`syncConfigForRecord`), the sync path and the event
    /// path must read one decision.
    private nonisolated let useStateUpdateWithEvents: Bool

    /// Whether an event's body can be merged into the opcode 107 frame: opcode 107 is on and
    /// messages are MessagePack, the only encoding whose event body is a MessagePack value.
    /// Decided once at init (#521 D10). In a hybrid configuration (`json` or `opcodeJsonArray`
    /// messages with `opcodeMessagePack` state updates) every event goes as its own frame, with
    /// no body attempt.
    private nonisolated let eventsMerge: Bool

    /// `useStateUpdateWithEvents` and `eventsMerge` for these encoders, decided once at init.
    private static func mergeDecisions(
        _ stateUpdateEncoder: any StateUpdateEncoder,
        _ messageEncoder: any TransportMessageEncoder
    ) -> (useStateUpdateWithEvents: Bool, eventsMerge: Bool) {
        let merged = stateUpdateEncoder.encoding == .opcodeMessagePack
        return (merged, merged && messageEncoder is MessagePackTransportMessageEncoder)
    }

    /// Merged broadcast frames with a shared broadcast key table: a late joiner needs a key scope
    /// reset (#90). Without key compression there is no table, and a reset would only cost every
    /// member an empty per-player firstSync frame.
    private var usesBroadcastKeyTable: Bool {
        useStateUpdateWithEvents
            && ((stateUpdateEncoder as? any DynamicKeyTableReporting)?.keepsDynamicKeyTables ?? true)
    }

    /// Optional transport profiler (when TRANSPORT_PROFILE_JSONL_PATH is set). Low-overhead: counters use atomics; latency uses sampling.
    /// Internal for TransportAdapter+Profiling extension access.
    let profiler: TransportProfilingActor?
    let profilerCounters: TransportProfilerCounters?
    /// Where the sync-lag counts go in the transport profile: `profilerCounters`, or a test's.
    private lazy var syncLagProfilerCounters: TransportProfilerCounters? = profilerCounters
    /// Sample 1 in N latency measurements to reduce overhead. Used only when profiler is set.
    var latencySampleCounter: UInt64 = 0

    /// Closure to create PlayerSession for guest users (when JWT validation is enabled but no token is provided).
    /// Only used when JWT validation is enabled, allowGuestMode is true, and no JWT token is provided.
    /// Default implementation uses the sessionID as playerID for deterministic guest identities.
    /// The land authenticates players (a JWT validator or configuration is set): a session
    /// without authenticated info is a guest and can't name a `playerID` (#209).
    public let authenticatesPlayers: Bool

    public var createGuestSession: @Sendable (SessionID, ClientID) -> PlayerSession = { sessionID, clientID in
        return PlayerSession(
            playerID: sessionID.rawValue,
            deviceID: clientID.rawValue,
            isGuest: true
        )
    }

    /// Callback to notify when land has been destroyed.
    /// Called after all destroy handlers (OnFinalize, AfterFinalize) have completed.
    var onLandDestroyedCallback: (@Sendable () async -> Void)?
    /// The host's stop of this instance on a land failure (#535 B2), set by `LandManager` at
    /// creation with the instance's epoch. It returns once the instance's sessions are closed
    /// (the stop's sessions-closed latch), never after the destroy, and false if no host
    /// stopped it (its server is gone). Without it, or on false, `landDidFail` closes the
    /// sessions itself.
    private(set) var landFailureHook: (@Sendable () async -> Bool)?

    /// Sets the host's stop for a land failure (`LandManager`, at creation).
    package func setLandFailureHook(_ hook: @escaping @Sendable () async -> Bool) {
        landFailureHook = hook
    }

    /// Creates a TransportAdapter that connects a LandKeeper to a Transport.
    ///
    /// **Core**: `keeper`, `transport`, `landID` (`transportSendQueue` is ignored and deprecated:
    /// every send goes through the adapter's ordered `OutboundWriter`)
    /// **Join / lifecycle**: `createGuestSession`, `onLandDestroyed`, `enableLegacyJoin`
    /// **Encoding**: Prefer `encodingConfig` (message + state encoding); otherwise use `codec`, `stateUpdateEncoder`, and optional `pathHashes` / `eventHashes` / `clientEventHashes`
    /// **Tuning**: `enableDirtyTracking`, `syncStrategy`, `expectedSchemaHash`; `transportEnvConfig` replaces the env lookup (tests/benchmarks), except `USE_SYNC_TABLES`, which a config takes from the environment unless it sets the property
    /// **Logging**: `logger` (optional). When provided, uses the same logger as the app (e.g. LandManager) for unified logging; when nil, creates a default colored logger. Benchmarks often pass a high log-level logger (e.g. .error) to reduce noise.
    ///
    /// Many options can be overridden at runtime via environment variables (e.g. `ENABLE_DIRTY_TRACKING`, `USE_SNAPSHOT_FOR_SYNC`).
    public init(
        keeper: LandKeeper<State>,
        transport: any Transport,
        transportSendQueue: (any TransportSendQueue)? = nil,
        landID: String,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        authenticatesPlayers: Bool = false,
        onLandDestroyed: (@Sendable () async -> Void)? = nil,
        enableLegacyJoin: Bool = false,
        enableDirtyTracking: Bool = true,
        syncStrategy: SyncStrategy = .delta,
        transportEnvConfig: TransportEnvConfig? = nil,
        expectedSchemaHash: String? = nil,
        codec: any TransportCodec = JSONTransportCodec(),
        stateUpdateEncoder: any StateUpdateEncoder = JSONStateUpdateEncoder(),
        encodingConfig: TransportEncodingConfig? = nil,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        suppressMissingPathHashesWarning: Bool = false,
        logger: Logger? = nil
    ) {
        self.init(
            keeper: keeper, transport: transport, transportSendQueue: transportSendQueue, landID: landID,
            createGuestSession: createGuestSession, authenticatesPlayers: authenticatesPlayers,
            onLandDestroyed: onLandDestroyed, enableLegacyJoin: enableLegacyJoin,
            enableDirtyTracking: enableDirtyTracking, syncStrategy: syncStrategy,
            transportEnvConfig: transportEnvConfig, expectedSchemaHash: expectedSchemaHash, codec: codec,
            stateUpdateEncoder: stateUpdateEncoder, encodingConfig: encodingConfig, pathHashes: pathHashes,
            eventHashes: eventHashes, clientEventHashes: clientEventHashes,
            suppressMissingPathHashesWarning: suppressMissingPathHashesWarning,
            logger: logger, joinsThroughRouter: false
        )
    }

    /// `init(keeper:…)`, told whether every join of this land comes through a router
    /// (`joinsThroughRouter`): the land manager knows, from whether it was given a shared
    /// transport. Without a router the adapter is the transport's delegate and runs its own joins,
    /// which send a standalone firstSync, so `rowAddressing` is not in effect.
    package init(
        keeper: LandKeeper<State>,
        transport: any Transport,
        transportSendQueue: (any TransportSendQueue)? = nil,
        landID: String,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        authenticatesPlayers: Bool = false,
        onLandDestroyed: (@Sendable () async -> Void)? = nil,
        enableLegacyJoin: Bool = false,
        enableDirtyTracking: Bool = true,
        syncStrategy: SyncStrategy = .delta,
        transportEnvConfig: TransportEnvConfig? = nil,
        expectedSchemaHash: String? = nil,
        codec: any TransportCodec = JSONTransportCodec(),
        stateUpdateEncoder: any StateUpdateEncoder = JSONStateUpdateEncoder(),
        encodingConfig: TransportEncodingConfig? = nil,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        suppressMissingPathHashesWarning: Bool = false,
        logger: Logger? = nil,
        joinsThroughRouter: Bool,
        eventEncodeCountsForTesting: EventEncodeCountsForTesting? = nil
    ) {
        // A replay runs in a headless reevaluation keeper; no adapter serves one (#612).
        precondition(keeper.isLive, "TransportAdapter binds only a live LandKeeper")
        self.keeper = keeper
        self.authenticatesPlayers = authenticatesPlayers
        self.transport = transport
        _ = transportSendQueue
        self.landID = landID
        let adapterScope = "TransportAdapter"
        self.logger = logger.map { $0.withScope(adapterScope) } ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.transport",
            scope: adapterScope
        )

        let unmappedPathLogger = self.logger
        let unmappedLandID = landID
        self.unmappedPathCounter = UnmappedPathCounter { path in
            unmappedPathLogger.error("State update patch dropped: its path has no schema pattern (no path index)", metadata: [
                "landID": .string(unmappedLandID),
                "path": .string(path),
            ])
        }

        let envConfig = transportEnvConfig ?? TransportEnvConfig.fromEnvironment(
            enableDirtyTrackingDefault: enableDirtyTracking,
            syncStrategyDefault: syncStrategy
        )
        // `rowAddressing` takes effect only where every join completes in a turn: joins through
        // the router. Its rows are the sync tables' slots, so it turns the tables on (their
        // frames are today's, byte for byte), which needs the delta strategy.
        let rowAddressingRequested = encodingConfig?.effective(pathHashes: pathHashes).rowAddressing ?? false
        let rowAddressing = rowAddressingRequested && joinsThroughRouter
            && envConfig.syncStrategy == .delta
        let usesSyncTables = (envConfig.useSyncTables || rowAddressing) && envConfig.syncStrategy == .delta
        self.rowAddressing = rowAddressing
        if let encodingConfig = encodingConfig?.withRowAddressing(rowAddressing) {
            self.codec = encodingConfig.makeCodec()
            let madeMessageEncoder = encodingConfig.makeMessageEncoder(
                eventHashes: eventHashes,
                clientEventHashes: clientEventHashes
            )
            self.messageEncoder = madeMessageEncoder
            self.actionResponseEncoder = madeMessageEncoder as? any ActionResponseFrameEncoder
            // Built here, at registration, and kept on the encoder: frames go out in the land's
            // canonical order (`CanonicalPatchOrder`).
            let madeStateUpdateEncoder = applyingCanonicalOrder(CanonicalPatchOrder.forState(State.self), to: encodingConfig.makeStateUpdateEncoder(
                pathHashes: pathHashes,
                warnIfMissingPathHashes: !suppressMissingPathHashesWarning,
                atomicLayout: AtomicLayoutTable.forState(State.self),
                unmappedPaths: unmappedPathCounter
            ))
            self.stateUpdateEncoder = madeStateUpdateEncoder
            (self.useStateUpdateWithEvents, self.eventsMerge) = Self.mergeDecisions(madeStateUpdateEncoder, madeMessageEncoder)
            self.pathHashes = pathHashes
            // The router requires the same list (from the same effective config).
            self.stateUpdateFeatures = encodingConfig.effective(pathHashes: pathHashes).stateUpdateFeatures
            self.tracksSyncLag = encodingConfig.syncSequence
            
            // Validate: Warn if opcodeJsonArray is used without pathHashes
            if !suppressMissingPathHashesWarning,
               encodingConfig.stateUpdate == .opcodeJsonArray,
               pathHashes == nil
            {
                self.logger.warning(
                    "⚠️ opcodeJsonArray encoding without pathHashes detected",
                    metadata: [
                        "landID": .string(landID),
                        "encoding": .string(encodingConfig.stateUpdate.rawValue),
                        "issue": .string("PathHash compression disabled (falling back to Legacy format)"),
                        "solution": .string("Provide pathHashes from your Land schema to enable full compression")
                    ]
                )
            }
        } else {
            self.codec = codec
            let madeMessageEncoder = JSONTransportMessageEncoder()
            let madeStateUpdateEncoder = applyingCanonicalOrder(CanonicalPatchOrder.forState(State.self), to: stateUpdateEncoder)
            self.messageEncoder = madeMessageEncoder
            self.actionResponseEncoder = madeMessageEncoder as? any ActionResponseFrameEncoder
            self.stateUpdateEncoder = madeStateUpdateEncoder
            (self.useStateUpdateWithEvents, self.eventsMerge) = Self.mergeDecisions(madeStateUpdateEncoder, madeMessageEncoder)
            self.pathHashes = pathHashes
            self.tracksSyncLag = false
            self.stateUpdateFeatures = []
        }

        self.enableLegacyJoin = enableLegacyJoin

        self.enableDirtyTracking = envConfig.enableDirtyTracking
        self.useSnapshotForSync = envConfig.useSnapshotForSync
        self.syncStrategy = envConfig.syncStrategy
        if usesSyncTables {
            // The encoder's own path trie, so the diff's patches carry the splits it would compute.
            let hasher = (self.stateUpdateEncoder as? any PathSplittingStateUpdateEncoder)?.splittingPathHasher
            let tables = SyncTableBroadcastDiff<State>(pathCursor: hasher?.rootCursor, typedLeafValues: envConfig.typedLeafValues, logger: logger)
            tables.emitsRowCreates = rowAddressing
            self.broadcastTables = tables
            self.syncEngine.broadcastCacheRetired = true
            // Once per state type: which fields gain nothing from the tables, and why.
            if SyncTableFallbackLog.shared.isFirst(State.self) {
                let fallbacks = syncTableFallbackFields(of: State.self)
                if !fallbacks.isEmpty {
                    self.logger.warning("Sync tables: fields diffed by the snapshot fallback", metadata: [
                        "state": .string("\(State.self)"),
                        "fields": .array(fallbacks.map { .string("\($0.field): \($0.reason)") })
                    ])
                }
            }
        } else {
            self.broadcastTables = nil
        }
        if usesSyncTables && envConfig.perPlayerSyncTables {
            self.perPlayerTables = SyncTablePerPlayerDiff<State>(typedLeafValues: envConfig.typedLeafValues, logger: logger)
            self.syncEngine.perPlayerCacheRetired = true
        } else {
            self.perPlayerTables = nil
        }
        self.expectedSchemaHash = expectedSchemaHash
        self.onLandDestroyedCallback = onLandDestroyed

        if let createGuestSession = createGuestSession {
            self.createGuestSession = createGuestSession
        }

        if let config = envConfig.profilingConfig, config.isEnabled {
            let p = TransportProfilingActor.shared(config: config)
            self.profiler = p
            self.profilerCounters = p.getCounters()
        } else {
            self.profiler = nil
            self.profilerCounters = nil
        }

        // Send latency is measured by the writer's consumer (dequeue to transport return),
        // sampled 1 in 100 like before. Not comparable with the pre-writer numbers, which
        // timed the producer's own send call.
        let onSent: (@Sendable (Duration, Int) -> Void)?
        if let profiler = self.profiler {
            let sampler = OutboundSendSampler(every: 100)
            onSent = { duration, _ in
                guard sampler.shouldSample() else { return }
                let ms = Double(duration.components.seconds) * 1000
                    + Double(duration.components.attoseconds) / 1e15
                Task { await profiler.recordSend(durationMs: ms) }
            }
        } else {
            onSent = nil
        }
        self.outboundWriter = OutboundWriter(
            transport: transport,
            maxBytes: envConfig.outboundWriterMaxBytes,
            logger: self.logger,
            onSent: onSent
        )

        self.decodingPipeline = MessageDecodingPipeline(
            codec: self.codec,
            opcodeDecoder: OpcodeTransportMessageDecoder(),
            enableLegacyJoin: enableLegacyJoin
        )
        self.routingTable = MessageRoutingTable()
        self.encodingPipeline = EncodingPipeline(
            stateUpdateEncoder: self.stateUpdateEncoder,
            messageEncoder: self.messageEncoder,
            landID: landID,
            encodeCounts: eventEncodeCountsForTesting
        )
        
        // Initialize event sending pipeline
        self.eventSendingPipeline = EventSendingPipeline(
            messageEncoder: self.messageEncoder,
            codec: self.codec,
            landID: landID,
            logger: self.logger,
            encodeCounts: eventEncodeCountsForTesting
        )
        self.membershipCoordinator = MembershipCoordinator()

        // Warn about a typo'd SYNC_STRATEGY only when the env lookup actually happened
        // (transportEnvConfig == nil): tests/benchmarks that inject transportEnvConfig
        // explicitly bypass that parsing, so there is nothing to warn about. (An injected config
        // still takes `USE_SYNC_TABLES` from the environment unless it sets the property.)
        if transportEnvConfig == nil,
           let rawSyncStrategy = ProcessInfo.processInfo.environment[SyncStrategy.environmentKey]
        {
            let trimmed = rawSyncStrategy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty, !SyncStrategy.isRecognised(rawSyncStrategy) {
                self.logger.warning("Unrecognised SYNC_STRATEGY value; using init default", metadata: [
                    "landID": .string(landID),
                    "value": .string(rawSyncStrategy),
                    "default": .string(self.syncStrategy.rawValue)
                ])
            }
        }

        self.logger.info("Transport encoding configured", metadata: [
            "landID": .string(landID),
            "messageEncoding": .string(self.messageEncoder.encoding.rawValue),
            "stateUpdateEncoding": .string(self.stateUpdateEncoder.encoding.rawValue),
            "dirtyTracking": .string(envConfig.enableDirtyTracking ? "on" : "off"),
            "snapshotForSync": .string(envConfig.useSnapshotForSync ? "on" : "off"),
            "syncTables": .string(usesSyncTables ? "on" : "off"),
            "rowAddressing": .string(rowAddressing ? "on" : "off"),
            "typedLeafValues": .string(usesSyncTables && envConfig.typedLeafValues ? "on" : "off"),
            "perPlayerSyncTables": .string(usesSyncTables && envConfig.perPlayerSyncTables ? "on" : "off"),
            "syncStrategy": .string(envConfig.syncStrategy.rawValue),
            "stateUpdateFeatures": .string(self.stateUpdateFeatures.joined(separator: ","))
        ])
        // Taken only by a logger that prints warnings, so a quiet adapter (a benchmark's) doesn't
        // use up the process's one report.
        let removedKeys = self.logger.logLevel <= .warning ? TransportRemovedEnvKeys.shared.takeFirst() : []
        if !removedKeys.isEmpty {
            self.logger.warning("Removed environment keys are set and ignored: each named key no longer exists (dirty tracking follows ENABLE_DIRTY_TRACKING; in-turn sync is always on)", metadata: [
                "keys": .string(removedKeys.joined(separator: ","))
            ])
        }
        // Row addressing needs the tables, so it keeps them on with `USE_SYNC_TABLES=false`:
        // say so, once per land, and how to reach the snapshot-diff path (the flag is a temporary
        // fallback).
        if rowAddressing && !envConfig.useSyncTables {
            self.logger.warning("USE_SYNC_TABLES=false is ignored: row addressing is in effect and needs the sync tables. Set ROW_ADDRESSING=false too for the snapshot-diff (legacy) path.", metadata: [
                "landID": .string(landID),
            ])
        }
        // Info, not a warning: the request is the default, so a land that can't have rows by
        // design (`fullSnapshot`, or a join that doesn't go through the router) logs this too.
        if rowAddressingRequested && !rowAddressing {
            self.logger.info("Row addressing requested but not in effect: it needs joins through the router and the delta sync strategy; this land sends today's entries", metadata: [
                "landID": .string(landID),
                "joinsThroughRouter": .string(joinsThroughRouter ? "yes" : "no"),
                "syncStrategy": .string(envConfig.syncStrategy.rawValue),
            ])
        }
    }

    // MARK: - Encoding Configuration

    /// Get the current message encoding format.
    public func getMessageEncoding() -> String {
        messageEncoder.encoding.rawValue
    }

    // MARK: - Dirty Tracking Configuration

    /// Check whether dirty tracking optimization is currently enabled.
    public func isDirtyTrackingEnabled() -> Bool {
        enableDirtyTracking
    }

    /// Enable or disable dirty tracking at runtime.
    ///
    /// - Parameter enabled: `true` to enable dirty tracking (default behavior),
    ///   `false` to disable and always generate full diffs.
    public func setDirtyTrackingEnabled(_ enabled: Bool) {
        enableDirtyTracking = enabled
    }
    
    // MARK: - PlayerSlot Allocation
    
    /// Allocate a deterministic playerSlot for a player based on accountKey.
    ///
    /// Uses FNV-1a hash for deterministic slot assignment, with linear probing for collision handling.
    /// If the player already has a slot (reconnection), returns the existing slot.
    ///
    /// - Parameters:
    ///   - accountKey: The account identifier (typically playerID)
    ///   - playerID: The PlayerID to associate with the slot
    /// - Returns: The allocated Int32 slot
    public func allocatePlayerSlot(accountKey: String, for playerID: PlayerID) -> Int32 {
        return membershipCoordinator.allocatePlayerSlot(accountKey: accountKey, for: playerID)
    }
    
    /// Get the playerSlot for an existing player.
    ///
    /// - Parameter playerID: The PlayerID to look up
    /// - Returns: The player's slot, or nil if not found
    public func getPlayerSlot(for playerID: PlayerID) -> Int32? {
        return membershipCoordinator.getPlayerSlot(for: playerID)
    }
    
    /// Get the PlayerID for a given slot.
    ///
    /// - Parameter slot: The slot to look up
    /// - Returns: The PlayerID, or nil if slot is not occupied
    public func getPlayerID(for slot: Int32) -> PlayerID? {
        return membershipCoordinator.getPlayerID(for: slot)
    }

    func _onConnectImpl(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo? = nil) async {
        // Register client with membership coordinator
        membershipCoordinator.registerClient(sessionID: sessionID, clientID: clientID, authInfo: authInfo)

        // Store JWT payload information if provided (e.g., from JWT validation)
        // This will be used during join request to populate PlayerSession
        if let authInfo = authInfo {
            logger.info("Client connected (authenticated, not joined yet): session=\(sessionID.rawValue), clientID=\(clientID.rawValue), playerID=\(authInfo.playerID), metadata=\(authInfo.metadata.count) fields")
        } else {
            logger.info("Client connected (not joined yet): session=\(sessionID.rawValue), clientID=\(clientID.rawValue)")
        }
    }

    func _onDisconnectImpl(sessionID: SessionID, clientID: ClientID, generation: UInt64? = nil) async {
        do {
            try await enqueueMembership {
                await self.handleDisconnectQueued(sessionID: sessionID, clientID: clientID, generation: generation)
            }
        } catch {
            logger.error("❌ Membership queue failed during disconnect", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string(String(describing: error))
            ])
        }
    }

    private func handleDisconnectQueued(sessionID: SessionID, clientID: ClientID, generation: UInt64? = nil) async {
        // A later connection under the ID took over: this disconnect is an older one's, and
        // changes nothing (#911). In the segment that acts.
        if let generation, let current = connectionGenerations[sessionID], current != generation { return }
        profilerCounters?.incrementDisconnects()
        // Late frames for this connection (e.g. an action response still in flight) are dropped,
        // so they cannot reach a later connection that reuses the SessionID.
        connectionGenerations.removeValue(forKey: sessionID)
        endedSessions.insert(sessionID)
        memberJoinAttempts.removeValue(forKey: sessionID)
        failInTurnJoin(sessionID: sessionID, reason: .disconnected, removeRecord: true)
        joiningSessions.removeValue(forKey: sessionID)
        // A drain in progress stops at its next step (its ticket ends below); what it still
        // holds is dropped now.
        if let drain = inboundAfterFlip.removeValue(forKey: sessionID) {
            inboundDroppedForJoiningSessions += drain.frames.count
        }
        inboundClosedSessions.remove(sessionID)
        sessionTickets.end(sessionID)
        syncLag.removeValue(forKey: sessionID)
        // Pending action responses: nothing is sent to the closed session. Cancelling a task
        // cancels its job (its caller stopped waiting); the task still reads the job's slot.
        actionResponseTickets.end(sessionID)
        actionResponseTasks.removeValue(forKey: sessionID)?.values.forEach { $0.cancel() }
        let joinedPlayerID = membershipCoordinator.playerID(for: sessionID)

        // If player had joined, handle leave
        if let playerID = joinedPlayerID {
            if logger.logLevel <= .debug {
                logger.debug("Player \(playerID.rawValue) disconnecting: session=\(sessionID.rawValue), clientID=\(clientID.rawValue)")
            }

            // Invalidating the membership bumps the player's version, so its queued `.player`
            // events are dropped for every session of the player, a remaining one included.
            let droppedPlayerEvents = pendingEventManager.currentPlayerEventCount(for: playerID) { player, version in
                membershipCoordinator.isPlayerCurrent(player, expected: version)
            }
            membershipCoordinator.invalidateMembership(sessionID: sessionID, playerID: playerID)
            membershipCoordinator.unregisterSession(sessionID: sessionID)

            // Now call keeper.leave(), which triggers the leave's sync
            do {
                try await keeper.leave(playerID: playerID, clientID: clientID, sessionID: sessionID)
                if logger.logLevel <= .debug {
                    logger.debug("Successfully called keeper.leave() for player \(playerID.rawValue)")
                }
            } catch {
                // Log error but don't block disconnection flow
                logger.error("❌ OnLeave handler failed", metadata: [
                    "sessionID": .string(sessionID.rawValue),
                    "playerID": .string(playerID.rawValue),
                    "error": .string(String(describing: error))
                ])
            }

            // The per-player state below (sync cache and firstSync mark, initial-sync marker,
            // player slot) belongs to the player, not to this session. Checked after the
            // `keeper.leave` await, in the same synchronous segment as the clearing: another
            // session of the player (a re-join admitted meanwhile, or one still in its initial
            // sync) keeps using it, so only the player's last session clears it.
            let otherSessions = membershipCoordinator.sessionIDs(for: playerID)
            if otherSessions.isEmpty {
                // Clear syncEngine cache for disconnected player
                // This ensures reconnection behaves like first connection
                syncEngine.clearCacheForDisconnectedPlayer(playerID)
                perPlayerTables?.clear(playerID)
                recordSyncStreamClear(playerID, outsideTurn: true)
                initialSyncingPlayers.removeValue(forKey: playerID)

                // Release playerSlot for this player
                membershipCoordinator.releasePlayerSlot(playerID: playerID)

                logger.info("Client disconnected: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
            } else {
                // Not reached since #531: a newer session of the player supersedes the older one
                // at its registration, so the older one has left the membership and its
                // disconnect runs no leave. Kept for several sessions per player (#539).
                logger.info("Client disconnected; player still has another session, its state is kept", metadata: [
                    "sessionID": .string(sessionID.rawValue),
                    "playerID": .string(playerID.rawValue),
                    "otherSessions": .stringConvertible(otherSessions.count),
                    "droppedPlayerEvents": .stringConvertible(droppedPlayerEvents)
                ])
            }
        } else {
            membershipCoordinator.unregisterSession(sessionID: sessionID)
            logger.info("Client disconnected (was not joined): session=\(sessionID.rawValue)")
        }
    }

    /// The public `registerSession` (#531): one membership change, in the membership queue like
    /// every other, after a check of the keeper's entry for the player.
    ///
    /// - The entry names another session or client (a newer keeper join of the player): the
    ///   registration is refused. The session isn't registered and is closed, as a join that
    ///   lost (`endJoinBeforeAdmission`), and `staleRegistrationRefusals` counts it.
    /// - Otherwise (the entry names this session or client, or the player has no entry): the
    ///   session is registered and the policy applies (`sessionPerPlayerPolicy`).
    ///
    /// The read is an await, and a keeper join outside this queue can move the entry after it.
    /// Then this registration commits a session the keeper no longer names, until that newer
    /// session is registered: its own check passes, and it supersedes this one.
    func _registerSessionQueued(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?,
        acceptedConnectionGeneration: UInt64?
    ) async {
        // The item's ticket, taken when it is enqueued: every later step receives it, and none
        // issues one after an `await` (#531). A teardown, which runs outside the queue, or a
        // disconnect of the session queued ahead ends it, and then the registration does nothing.
        // A ticket issued here is held by every registration queued with it until the last one
        // is done (`releaseRegistrationTicket`).
        let ticket: Ticket<SessionID>
        if let existing = sessionTickets.ticket(for: sessionID) {
            ticket = existing
            if registrationTicketHolders[sessionID]?.ticket == existing {
                registrationTicketHolders[sessionID]?.holders += 1
            }
        } else {
            ticket = sessionTickets.issue(sessionID)
            registrationTicketHolders[sessionID] = RegistrationTicketHolders(ticket: ticket, holders: 1)
        }
        do {
            try await enqueueMembership {
                await self.registerSessionCheckingKeeper(
                    sessionID: sessionID,
                    clientID: clientID,
                    playerID: playerID,
                    authInfo: authInfo,
                    acceptedConnectionGeneration: acceptedConnectionGeneration,
                    ticket: ticket
                )
            }
        } catch {
            logger.error("❌ Membership queue failed during registerSession", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string(String(describing: error))
            ])
        }
    }

    /// Registrations refused because the keeper's entry for the player named another session
    /// or client (#531).
    private(set) var staleRegistrationRefusals = 0

    /// A session ticket a registration's enqueue issued (the session had none), and how many
    /// queued registrations of the session hold it. It isn't the session's until one of them
    /// registers it: the last holder to finish ends it when none did, so a refused registration
    /// doesn't end it under a later one queued with it (#531).
    struct RegistrationTicketHolders {
        let ticket: Ticket<SessionID>
        var holders: Int
    }

    private var registrationTicketHolders: [SessionID: RegistrationTicketHolders] = [:]

    /// One holder of `ticket` is done. The last one ends the ticket, unless the session is a
    /// member by now (a holder registered it; the ticket, or its renewal, is the session's).
    private func releaseRegistrationTicket(_ sessionID: SessionID, _ ticket: Ticket<SessionID>) {
        guard var held = registrationTicketHolders[sessionID], held.ticket == ticket else { return }
        held.holders -= 1
        guard held.holders == 0 else {
            registrationTicketHolders[sessionID] = held
            return
        }
        registrationTicketHolders.removeValue(forKey: sessionID)
        if membershipCoordinator.playerID(for: sessionID) == nil {
            sessionTickets.end(ticket)
        }
    }

    private func registerSessionCheckingKeeper(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?,
        acceptedConnectionGeneration: UInt64?,
        ticket queuedTicket: Ticket<SessionID>
    ) async {
        // In the segment that returns, whatever the outcome.
        defer { releaseRegistrationTicket(sessionID, queuedTicket) }
        // Checked after the keeper read: a teardown outside this queue can end the ticket
        // during the await. Then the land is gone, and the registration neither refuses nor
        // registers. A registration ahead of this one that rebound the session renewed the
        // ticket instead of ending it: this one goes on under the renewed ticket, so the later
        // registration wins, as the queue orders them.
        let entry = await keeper.entrySession(for: playerID)
        await holds.at(.registrationAfterKeeperRead)
        guard let ticket = sessionTickets.resolve(queuedTicket) else {
            logger.info("Registration dropped: its ticket ended before it ran (a teardown, or the session's disconnect)", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "playerID": .string(playerID.rawValue),
            ])
            return
        }
        if let entry {
            // The keeper's sender check, `rejectSenderIfSuperseded`: a recorded client or
            // session that differs is another join's.
            let otherClient = entry.clientID.map { $0 != clientID } ?? false
            let otherSession = entry.sessionID.map { $0 != sessionID } ?? false
            if otherClient || otherSession {
                staleRegistrationRefusals += 1
                logger.warning("Registration refused: the keeper's entry for the player names another session", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "sessionID": .string(sessionID.rawValue),
                    "clientID": .string(clientID.rawValue),
                    "entrySessionID": .string(entry.sessionID?.rawValue ?? "-"),
                    "refusedTotal": .stringConvertible(staleRegistrationRefusals),
                ])
                endedSessions.insert(sessionID)
                // A ticket this registration's enqueue issued is ended by its last holder (the
                // `defer`), not here: a registration of the session queued with it still holds it.
                // Without a generation (a caller that passed none), the close is by ID.
                closeSessionDetached(sessionID, generation: acceptedConnectionGeneration)
                return
            }
        }
        await _registerSessionImpl(
            sessionID: sessionID,
            clientID: clientID,
            playerID: playerID,
            authInfo: authInfo,
            acceptedConnectionGeneration: acceptedConnectionGeneration,
            ticket: ticket
        )
    }

    /// Closes `sessionID` from a detached task, only while its connection is the one with
    /// `generation`; with nil, whatever connection has the ID. A transport that doesn't
    /// implement the generation-aware close (the `Transport` default) closes by ID (#531).
    /// `close` is what the connection is closed with: a plain 1000 unless the caller says
    /// otherwise (a supersede whose writer has finished passes `.superseded`, #861). It doesn't
    /// wait for frames queued for the session; `closeSessionBehindQueuedFrames` does (#909).
    func closeSessionDetached(_ sessionID: SessionID, generation: UInt64?, with close: SessionClose = .normal) {
        let transport = self.transport
        guard tracksDetachedClosesForTesting else {
            Task { await transport.closeSession(sessionID, with: close, generation: generation) }
            return
        }
        let id = nextDetachedCloseID
        nextDetachedCloseID += 1
        // The Task ends on this actor, after this segment, so the handle is stored before then.
        // Weak: a close that never returns doesn't keep the adapter.
        detachedCloses[id] = Task { [weak self] in
            await transport.closeSession(sessionID, with: close, generation: generation)
            await self?.detachedCloseEnded(id)
        }
    }

    /// Closes `sessionID` behind every frame already queued for it in the outbound writer, with
    /// `close`, only while its connection is the one with `generation` (nil: any), so a frame
    /// queued before the decision reaches the client before the close (#909). The session must
    /// already be ended, so nothing is queued for it after the close. When an ordered close is
    /// already pending for the connection, the transport ignores this one: the first close
    /// decided is the one the client gets (#911).
    ///
    /// Synchronous, and must stay so: the enqueue, the check of its result and the fallback run
    /// in one segment, so no frame is queued for the session and no generation changes between
    /// them. A finished writer refuses the close; it then goes out at once, from a task.
    func closeSessionBehindQueuedFrames(_ sessionID: SessionID, generation: UInt64?, with close: SessionClose) {
        let result = outboundWriter.enqueueClose([ClosingSession(sessionID: sessionID, generation: generation, close: close)])
        guard result == .accepted else {
            closeSessionDetached(sessionID, generation: generation, with: close)
            return
        }
        if tracksDetachedClosesForTesting { queuedCloses.append((sessionID, generation)) }
    }

    private func detachedCloseEnded(_ id: UInt64) {
        detachedCloses[id] = nil
    }

    /// Tests only (#555): whether `closeSessionDetached` keeps each close's handle, so
    /// `waitForDetachedClosesForTesting` can await it. Off in production: no tracking cost.
    private var tracksDetachedClosesForTesting = false
    /// The closes `closeSessionDetached` started while tracking, by id, until each returns.
    private var detachedCloses: [UInt64: Task<Void, Never>] = [:]
    private var nextDetachedCloseID: UInt64 = 0

    /// Tests only (#555): from now on, keep each detached close's handle until it returns.
    package func trackDetachedClosesForTesting() {
        tracksDetachedClosesForTesting = true
    }

    /// The closes `closeSessionBehindQueuedFrames` put in the writer while tracking, with the
    /// connection each is for (#909).
    private var queuedCloses: [(sessionID: SessionID, generation: UInt64?)] = []

    /// Tests only (#909): the closes put behind queued frames (a supersede's) since
    /// `trackDetachedClosesForTesting`, in order. Each one's connection closes once the
    /// transport's drain reaches its marker, after the writer handed it over.
    package func queuedClosesForTesting() -> [(sessionID: SessionID, generation: UInt64?)] {
        queuedCloses
    }

    /// Tests only (#555): returns once every close `closeSessionDetached` started (a supersede's
    /// fallback, a refused registration's) since `trackDetachedClosesForTesting` has returned
    /// from the transport.
    package func waitForDetachedClosesForTesting() async {
        while let task = detachedCloses.values.first {
            await task.value
        }
    }

    /// The realtime adapter's rule for a player's sessions (#531): newest wins.
    package let sessionPerPlayerPolicy: SessionPerPlayerPolicy = .replaceOld

    /// Applies `sessionPerPlayerPolicy` for `sessionID`, the player's newest session. Both join
    /// paths call it, in the segment that makes the session a member.
    private func applySessionPerPlayerPolicy(to playerID: PlayerID, keeping sessionID: SessionID) {
        switch sessionPerPlayerPolicy {
        case .replaceOld:
            supersedeSessions(of: playerID, keeping: sessionID)
        }
    }

    /// Registers a session in the membership queue, without the keeper check: the public
    /// `registerSession` after its check, and `performJoinQueued` after its keeper join and
    /// admission. The player's other sessions are superseded (`sessionPerPlayerPolicy`).
    ///
    /// - Parameter ticket: The session's ticket, taken before the caller's first `await`: the
    ///   public path's at its enqueue, the library join's at its admission. This function issues
    ///   none. Not current any more (a teardown): nothing is registered.
    func _registerSessionImpl(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?,
        acceptedConnectionGeneration: UInt64? = nil,
        ticket carried: Ticket<SessionID>
    ) async {
        guard var ticket = sessionTickets.resolve(carried) else { return }
        // Rebinding the session to another player starts a new generation: work captured for
        // the previous player's binding (an initial sync reading the state) must not act on it.
        if let previous = membershipCoordinator.playerID(for: sessionID), previous != playerID {
            guard let renewed = sessionTickets.renew(ticket) else { return }
            ticket = renewed
            syncLag.removeValue(forKey: sessionID)
        }
        applySessionPerPlayerPolicy(to: playerID, keeping: sessionID)
        _ = membershipCoordinator.registerPlayer(
            sessionID: sessionID,
            playerID: playerID,
            authInfo: authInfo
        )
        membershipCoordinator.registerClient(sessionID: sessionID, clientID: clientID)

        // Record the session's connection generation (see `connectionGenerations`). Group
        // targets are expanded from this adapter's membership, not from the transport's maps.
        // Under a ticket taken before the await: a disconnect, a supersede or a teardown during
        // it ends the session, and the write must not bring back an entry for it (#531).
        endedSessions.remove(sessionID)
        await holds.at(.registrationGeneration)
        if let webSocketTransport = transport as? WebSocketTransport {
            let current = await webSocketTransport.registerSession(sessionID, for: playerID)
            sessionTickets.ifCurrent(ticket) { _ in
                connectionGenerations[sessionID] = acceptedConnectionGeneration ?? current
            }
        } else if let acceptedConnectionGeneration {
            sessionTickets.ifCurrent(ticket) { _ in
                connectionGenerations[sessionID] = acceptedConnectionGeneration
            }
        }

        logger.info("Session registered via Router: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
    }

    /// `endSessionTicketsForTeardown` calls so far (tests: which instance a shutdown reached).
    package private(set) var teardownTicketEnds = 0

    /// Ends every session ticket, at the land's teardown: work still holding one (an initial
    /// sync) commits nothing for the destroyed land.
    package func endSessionTicketsForTeardown() {
        teardownTicketEnds += 1
        sessionTickets.endAll()
        syncLag.removeAll()
        // Every drain stops: what they still hold is dropped now, and a frame one of them has
        // popped is dropped when its dispatch step finds the ended ticket.
        for drain in inboundAfterFlip.values {
            inboundDroppedForJoiningSessions += drain.frames.count
        }
        inboundAfterFlip.removeAll()
        for sessionID in Array(joinWaiters.keys) {
            failInTurnJoin(sessionID: sessionID, reason: .landClosed)
        }
    }

    // MARK: - Outbound target expansion

    /// Joined sessions of this land, for `.broadcast` frames.
    func joinedSessionIDs() -> [SessionID] {
        membershipCoordinator.allJoinedEntries().map(\.sessionID)
    }

    /// Whether `sessionID` is admitted and waiting for its initial sync (`joiningSessions`).
    func isJoining(_ sessionID: SessionID) -> Bool {
        joiningSessions[sessionID] != nil
    }

    /// Whether `sessionID` is admitted by a join that completes in a turn and hasn't flipped.
    func isJoiningInTurn(_ sessionID: SessionID) -> Bool {
        joiningSessions[sessionID]?.inTurn != nil
    }

    /// This land's sessions of `playerID`, for `.player` frames.
    func membershipSessionIDs(for playerID: PlayerID) -> [SessionID] {
        membershipCoordinator.sessionIDs(for: playerID)
    }

    // MARK: - Join Helpers (Shared Logic)

    /// Execute a block while marking player as initial syncing.
    /// Automatically removes the player from initialSyncingPlayers when done (even on error).
    /// This ensures a sync phase skips this player during initial sync.
    ///
    /// `sessionID`'s `.joining` mark (`joiningSessions`) is handed over to the initial-sync
    /// mark here, in one synchronous segment, so the session is excluded throughout. The
    /// handover is guarded in that segment: when the session is neither joining nor a member as
    /// `playerID` any more (its disconnect ran after `performJoin` returned), nothing runs and
    /// `nil` is returned, so no firstSync re-creates the per-player state the disconnect
    /// cleared. A session that is a member without an admission (registered directly) runs.
    ///
    /// A `.joining` mark of another player (the SessionID was admitted again meanwhile) is
    /// left alone and nothing runs.
    ///
    /// `operation` gets the session's ticket (`sessionTickets`): the admission's, or for a
    /// directly registered member its current one (issued here if it has none). Work after an
    /// `await` in `operation` acts only while that ticket is current.
    private func withInitialSync<T: Sendable>(
        for playerID: PlayerID,
        sessionID: SessionID,
        operation: (Ticket<SessionID>) async throws -> T
    ) async rethrows -> T? {
        let ticket: Ticket<SessionID>
        if let joining = joiningSessions[sessionID] {
            // Another player's admission of this SessionID (the session ended and was admitted
            // again meanwhile): it isn't this initial sync's to take.
            guard joining.playerID == playerID else {
                logger.info("Initial sync skipped: the session was admitted again for another player", metadata: [
                    "sessionID": .string(sessionID.rawValue),
                    "playerID": .string(playerID.rawValue),
                    "admittedPlayerID": .string(joining.playerID.rawValue),
                ])
                return nil
            }
            joiningSessions.removeValue(forKey: sessionID)
            ticket = joining.ticket
            noteSessionJoined(sessionID, playerID: playerID)
        } else if membershipCoordinator.playerID(for: sessionID) == playerID {
            ticket = sessionTickets.ticket(for: sessionID) ?? sessionTickets.issue(sessionID)
        } else {
            logger.info("Initial sync skipped: the session left before it started", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "playerID": .string(playerID.rawValue),
            ])
            return nil
        }
        initialSyncingPlayers[playerID] = .some(ticket)
        defer {
            if initialSyncingPlayers[playerID] == .some(.some(ticket)) {
                initialSyncingPlayers.removeValue(forKey: playerID)
            }
        }
        return try await operation(ticket)
    }


    // MARK: - Admission (#69)

    /// Admits `sessionID` as joining `playerID`: membership, player slot and the `.joining`
    /// mark, in one synchronous segment. Returns the slot.
    ///
    /// One session per player, newest wins (#92): the player's other sessions are superseded in
    /// the same segment (`supersedeSessions`), so there is never a moment with two members.
    private func admitJoining(
        sessionID: SessionID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?,
        inTurn: (joinSequence: Int64?, joinResponse: @Sendable (PlayerID, Int32) -> Data?, joinDeadline: ContinuousClock.Instant?, attemptEnd: JoinAttemptEnd?)? = nil
    ) -> Int32 {
        applySessionPerPlayerPolicy(to: playerID, keeping: sessionID)
        _ = membershipCoordinator.registerPlayer(
            sessionID: sessionID,
            playerID: playerID,
            authInfo: authInfo
        )
        // Allocate playerSlot (uses playerID as accountKey by default)
        let slot = allocatePlayerSlot(accountKey: playerID.rawValue, for: playerID)
        let ticket = sessionTickets.issue(sessionID)
        var joining = JoiningSession(playerID: playerID, playerSlot: slot, ticket: ticket)
        if let inTurn, let response = inTurn.joinResponse(playerID, slot) {
            nextInTurnJoinOrder += 1
            joining.inTurn = InTurnJoin(
                joinSequence: inTurn.joinSequence,
                order: nextInTurnJoinOrder,
                joinResponse: response,
                consumed: inTurn.joinSequence == nil,
                attemptEnd: inTurn.attemptEnd
            )
            startJoinWaiter(sessionID: sessionID, ticket: ticket, joinDeadline: inTurn.joinDeadline)
        }
        joiningSessions[sessionID] = joining
        return slot
    }

    /// The waiter of an in-turn join and its timeout. The timeout runs through the membership
    /// queue and acts only while the admission's ticket is current and the session still joins.
    /// So it is a lower bound: another join's resolvers ahead in the queue can delay it, and a
    /// sync that commits meanwhile still flips the join (the late timeout then does nothing).
    ///
    /// The flip waits for what is left of the join's budget (`JOIN_TIMEOUT_MS`, #104), from the
    /// router's deadline, or, for a join admitted without one, from now; the deprecated
    /// `JOIN_FLIP_TIMEOUT_MS` still caps it. No budget and no cap: no timeout.
    /// A flip waiter's timeout: the test override, else what is left of the join budget; nil for
    /// none. An explicit `.zero` override is "no timeout" (#555), as the router's join budget
    /// override is; a `.zero` left of an expired deadline still times out at once.
    static func joinFlipTimeout(override: Duration?, deadline: ContinuousClock.Instant?) -> Duration? {
        if override == .zero { return nil }
        return override ?? JoinTimeoutConfig.flipWait(deadline: deadline)
    }

    private func startJoinWaiter(sessionID: SessionID, ticket: Ticket<SessionID>, joinDeadline: ContinuousClock.Instant?) {
        joinWaiters[sessionID]?.resolve(.failure(.superseded))
        let waiter = JoinWaiter(ticket: ticket)
        joinWaiters[sessionID] = waiter
        let deadline = joinDeadline ?? JoinTimeoutConfig.budget.map { ContinuousClock.now + $0 }
        guard let timeout = Self.joinFlipTimeout(override: joinFlipTimeoutForTesting, deadline: deadline) else { return }
        waiter.timeout = Task { [weak self] in
            guard (try? await safeTaskSleep(for: timeout)) != nil, let adapter = self else { return }
            try? await adapter.enqueueMembership {
                await adapter.timeOutJoin(sessionID: sessionID, ticket: ticket)
            }
        }
    }

    /// The router's join budget ran out before it saw the session's admission (#104). Decided
    /// here, in one segment, by where the admission is. One not started (not yet enqueued, or
    /// queued in the membership queue) is ended: `attemptEnd` is marked, so it is refused when it
    /// runs, before the keeper's join, and `finalFrame` goes out as the session's last
    /// frame, with the close behind it; returns true. One already in the keeper's join, or
    /// done, is left alone (false): the keeper's state already changed or is changing, its
    /// resolvers are bounded by their own deadline, and an in-turn join's flip waits for what is
    /// left of the budget. So is one whose keeper join returned (or threw) before the router saw
    /// it (`attemptEnd.isKeeperJoinStarted`): the router's handler answers with its outcome.
    ///
    /// - Parameter connectionGeneration: The connection the router accepted for the session. The
    ///   session was never admitted, so the adapter has none recorded: the final frame and every
    ///   close carry this one, and act only on that connection (#531). Nil: by ID.
    func endJoinBeforeAdmission(
        _ sessionID: SessionID,
        finalFrame: EncodedFrame?,
        attemptEnd: JoinAttemptEnd,
        connectionGeneration: UInt64? = nil
    ) -> Bool {
        guard !attemptEnd.isKeeperJoinStarted,
              expectedAdmissions[sessionID] == nil,
              joiningSessions[sessionID] == nil,
              membershipCoordinator.playerID(for: sessionID) == nil
        else { return false }
        // Not `endedSessions` alone: it evicts its oldest entries, and an admission can stay
        // queued while thousands of the land's sessions end.
        attemptEnd.markEnded()
        if let finalFrame {
            // The router's join error, with the kind of the encoder that wrote it.
            sendFinalFrameAndClose(finalFrame.data, kind: finalFrame.kind, to: sessionID, generation: connectionGeneration)
        } else {
            endedSessions.insert(sessionID)
            closeSessionDetached(sessionID, generation: connectionGeneration)
        }
        return true
    }

    private func timeOutJoin(sessionID: SessionID, ticket: Ticket<SessionID>) {
        guard joiningSessions[sessionID]?.ticket == ticket, joiningSessions[sessionID]?.inTurn != nil else { return }
        failInTurnJoin(sessionID: sessionID, reason: .timeout)
    }

    /// Fails an in-turn join with `reason`: its waiter resumes with it, and the session never
    /// flips. The record stays (the session remains excluded from recipients) until the
    /// session's disconnect removes it; `removeRecord` removes it now.
    private func failInTurnJoin(sessionID: SessionID, reason: JoinFlipError, removeRecord: Bool = false) {
        discardHeldEvents(of: sessionID, includingQueued: removeRecord)
        discardDeferredInbound(of: sessionID)
        if removeRecord {
            joiningSessions.removeValue(forKey: sessionID)
        } else {
            joiningSessions[sessionID]?.inTurn?.failed = true
        }
        guard let waiter = joinWaiters[sessionID], waiter.result == nil else { return }
        inTurnJoinFailures[reason, default: 0] += 1
        logger.info("Join failed before it completed", metadata: [
            "sessionID": .string(sessionID.rawValue),
            "reason": .string("\(reason)"),
        ])
        waiter.resolve(.failure(reason))
    }

    /// Waits until the in-turn join of `sessionID` flips (returns) or fails (throws
    /// `JoinFlipError`). Returns at once when the session has no such join.
    public func awaitJoined(sessionID: SessionID) async throws {
        guard let waiter = joinWaiters[sessionID] else { return }
        defer {
            if joinWaiters[sessionID] === waiter { joinWaiters.removeValue(forKey: sessionID) }
        }
        if let result = waiter.result {
            try result.get()
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if let result = waiter.result {
                continuation.resume(with: result.mapError { $0 as any Error })
            } else {
                waiter.continuation = continuation
            }
        }
    }

    /// Ready in-turn joins (consumed, registered, current), first in first out, at most `limit`.
    private func readyInTurnJoins(limit: Int) -> [(sessionID: SessionID, joining: JoiningSession)] {
        guard !joinFlipHeldForTesting else { return [] }
        return joiningSessions
            .filter { entry in
                guard let inTurn = entry.value.inTurn, inTurn.isReadyToFlip else { return false }
                return sessionTickets.isCurrent(entry.value.ticket)
            }
            .map { (sessionID: $0.key, joining: $0.value) }
            .sorted { ($0.joining.inTurn?.order ?? 0) < ($1.joining.inTurn?.order ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    /// `LandKeeperTransport.noteJoinInputsConsumed`, on the keeper's executor.
    func noteJoinInputsConsumedIsolated(_ results: [JoinInputResult]) {
        for result in results {
            guard let (sessionID, _) = joiningSessions.first(where: { $0.value.inTurn?.joinSequence == result.sequence }) else {
                continue
            }
            joiningSessions[sessionID]?.inTurn?.consumed = true
        }
    }

    /// Whether `sessionID`'s in-turn join has registered with the transport (tests only).
    func isInTurnJoinRegisteredForTesting(_ sessionID: SessionID) -> Bool {
        joiningSessions[sessionID]?.inTurn?.transportRegistered == true
    }

    /// Whether a join is ready to flip (tests only).
    func hasJoinsAwaitingSyncForTesting() -> Bool {
        hasJoinsAwaitingSyncIsolated()
    }

    /// `LandKeeperTransport.hasJoinsAwaitingSync`, on the keeper's executor.
    func hasJoinsAwaitingSyncIsolated() -> Bool {
        joiningSessions.values.contains { joining in
            joining.inTurn?.isAwaitingJoinSync == true && sessionTickets.isCurrent(joining.ticket)
        }
    }

    /// Sessions superseded by a newer join of their player so far.
    private(set) var supersededSessionCount = 0
    /// Router joins refused as stale before the keeper's join (`staleJoinAttempt`, #97).
    package private(set) var staleJoinAttemptsRefused = 0

    /// Ends every session of `playerID` other than `sessionID` (newest wins, #92). For the game
    /// this is OnLeave then OnJoin: the keeper's join already left the old entry. Here, in the
    /// admission segment:
    /// - each old session leaves the membership (it stops being a recipient and its inbound
    ///   finds no player), is ended (its frames are dropped) and its connection is closed; its
    ///   later disconnect callback finds no membership, so it clears nothing and doesn't leave
    ///   the keeper again; the close is 4017 `superseded` (#861), so the client can tell it from
    ///   a plain close;
    /// - an old session still joining loses its mark;
    /// - the player's per-player sync state (cache, firstSync mark, initial-sync mark) is
    ///   cleared, and the clear recorded, so the new session's firstSync starts from empty like
    ///   a first join. The player slot is kept.
    private func supersedeSessions(of playerID: PlayerID, keeping sessionID: SessionID) {
        let superseded = membershipCoordinator.sessionIDs(for: playerID).filter { $0 != sessionID }
        guard !superseded.isEmpty else { return }
        for old in superseded {
            // The close runs later, behind the frames queued for the session: it closes only
            // this connection, never a later one that reuses the ID (#531).
            let generation = connectionGenerations[old]
            // Before the membership goes: its queued targeted events still match it, and are
            // counted with its held ones.
            failInTurnJoin(sessionID: old, reason: .superseded, removeRecord: true)
            if let drain = inboundAfterFlip.removeValue(forKey: old) {
                inboundDroppedForJoiningSessions += drain.frames.count
            }
            membershipCoordinator.invalidateMembership(sessionID: old, playerID: playerID)
            membershipCoordinator.unregisterSession(sessionID: old)
            sessionTickets.end(old)
            syncLag.removeValue(forKey: old)
            connectionGenerations.removeValue(forKey: old)
            endedSessions.insert(old)
            memberJoinAttempts.removeValue(forKey: old)
            supersededSessionCount += 1
            logger.info("Session superseded by a newer join of its player", metadata: [
                "playerID": .string(playerID.rawValue),
                "supersededSessionID": .string(old.rawValue),
                "newSessionID": .string(sessionID.rawValue),
                "supersededTotal": .stringConvertible(supersededSessionCount),
            ])
            closeSessionBehindQueuedFrames(old, generation: generation, with: .superseded)
        }
        syncEngine.clearCacheForDisconnectedPlayer(playerID)
        perPlayerTables?.clear(playerID)
        recordSyncStreamClear(playerID)
        initialSyncingPlayers.removeValue(forKey: playerID)
    }

    /// The keeper's stale-join check by the player CanJoin resolved
    /// (`LandKeeperTransport.refusesResolvedJoin`, #234), on the keeper's executor.
    ///
    /// It holds until the keeper acts on the player: every writer of `memberJoinAttempts` and of
    /// the player's member sessions runs in the membership queue, which `performJoinQueued`
    /// holds for the whole keeper join, or synchronously inside this join (its admission). No
    /// other adapter reaches this keeper.
    func refusesResolvedJoinIsolated(playerID: PlayerID, sessionID: SessionID) -> Bool {
        guard let attempt = expectedAdmissions[sessionID]?.joinAttempt else { return false }
        return staleJoinAttempt(attempt, sessionID: sessionID, playerID: playerID)
    }

    /// The keeper's in-turn admission (`LandKeeperTransport.admitJoiningSession`), on the
    /// keeper's executor. Admits only a join `performJoinQueued` is waiting for.
    func admitJoiningSessionIsolated(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        guard let expected = expectedAdmissions.removeValue(forKey: sessionID) else { return .notAdmitted }
        _ = admitJoining(
            sessionID: sessionID,
            playerID: playerID,
            authInfo: expected.authInfo,
            inTurn: expected.joinResponse.map { (joinSequence: joinSequence, joinResponse: $0, joinDeadline: expected.joinDeadline, attemptEnd: expected.attemptEnd) }
        )
        inTurnAdmissionCountForTesting += 1
        return joiningSessions[sessionID]?.inTurn != nil ? .admittedCompletesInTurn : .admitted
    }

    /// Undoes an admission whose join then failed (the keeper's join threw after admitting):
    /// the session's player membership is removed, and the slot is released when the player
    /// has no other session. The connection stays registered (client and auth), so the client
    /// can send another join on it.
    private func abandonJoining(sessionID: SessionID) {
        discardHeldEvents(of: sessionID, includingQueued: true)
        discardDeferredInbound(of: sessionID)
        guard let joining = joiningSessions.removeValue(forKey: sessionID) else { return }
        // The join's caller gets the join's error; nobody awaits this waiter.
        joinWaiters.removeValue(forKey: sessionID)?.resolve(.failure(.disconnected))
        sessionTickets.end(joining.ticket)
        membershipCoordinator.removeJoinedPlayer(sessionID: sessionID)
        if membershipCoordinator.sessionIDs(for: joining.playerID).isEmpty {
            membershipCoordinator.releasePlayerSlot(playerID: joining.playerID)
        }
    }
    
    /// Mark a player as undergoing initial sync to avoid pre-firstSync updates.
    /// 
    /// Note: Prefer using `withInitialSync(for:operation:)` for automatic cleanup.
    /// This method is kept for backward compatibility but should be avoided in new code.
    func beginInitialSync(for playerID: PlayerID) {
        initialSyncingPlayers.updateValue(nil, forKey: playerID)
    }

    /// Whether `playerID` is marked as in its initial sync (tests only).
    func isInitialSyncingForTesting(_ playerID: PlayerID) -> Bool {
        initialSyncingPlayers[playerID] != nil
    }

    /// Why a join request's `playerID` is rejected (#209), or nil when it isn't.
    /// - With authenticated info (a JWT), the join may name no `playerID` or the token's own;
    ///   any other one is a `.tokenMismatch`.
    /// - On a land that authenticates players (a JWT validator or configuration is set), a
    ///   session without authenticated info is a guest: a join that names a `playerID` is
    ///   `.unauthenticated` (fail closed; it could otherwise take over an authenticated player
    ///   through newest-wins, #92). One that names none joins as a guest.
    /// - Otherwise the join's `playerID` is used.
    /// Both join paths (`LandRouter` and `handleJoinRequest`) check it before their first await,
    /// and answer either reason with `JOIN_PLAYER_MISMATCH`.
    public static func joinIdentityRejection(
        requestedPlayerID: String?,
        authInfo: AuthenticatedInfo?,
        authenticatesPlayers: Bool
    ) -> JoinIdentityRejection? {
        guard let requestedPlayerID else { return nil }
        if let authInfo {
            return requestedPlayerID == authInfo.playerID ? nil : .tokenMismatch(tokenPlayerID: authInfo.playerID)
        }
        return authenticatesPlayers ? .unauthenticated : nil
    }

    /// Prepare PlayerSession from join request parameters.
    /// The playerID comes from the authenticated info (JWT) when there is one, else from the join
    /// message, else from the guest session (#209: a token's identity is never overridden; a join
    /// naming another player is rejected before this, see `playerIDMismatch`). The deviceID and
    /// metadata keep the order join message > JWT payload > guest session.
    ///
    /// This is shared logic used by both LandRouter and TransportAdapter.handleJoinRequest.
    public func preparePlayerSession(
        sessionID: SessionID,
        clientID: ClientID,
        requestedPlayerID: String?,
        deviceID: String?,
        metadata: [String: AnyCodable]?,
        authInfo: AuthenticatedInfo?
    ) -> PlayerSession {
        let jwtAuthInfo = authInfo ?? membershipCoordinator.authInfo(for: sessionID)
        let guestSession: PlayerSession? = (requestedPlayerID == nil && jwtAuthInfo == nil)
            ? createGuestSession(sessionID, clientID)
            : nil

        // Determine playerID: JWT payload > join message > guest session (#209)
        let finalPlayerID: String = jwtAuthInfo?.playerID
            ?? requestedPlayerID
            ?? guestSession?.playerID
            ?? sessionID.rawValue

        // Determine deviceID: join message > JWT payload > guest session
        let finalDeviceID: String? = deviceID
            ?? jwtAuthInfo?.deviceID
            ?? guestSession?.deviceID
            ?? clientID.rawValue

        // Merge metadata: join message metadata > JWT payload metadata > guest session metadata
        var finalMetadata: [String: String] = [:]

        // Start with JWT payload metadata (if available)
        if let jwtMetadata = jwtAuthInfo?.metadata {
            finalMetadata.merge(jwtMetadata) { (_, new) in new }
        }

        // Override with join message metadata (if provided)
        if let joinMetadata = metadata {
            let joinMetadataDict: [String: String] = joinMetadata.reduce(into: [:]) { result, pair in
                // Extract underlying value from AnyCodable and convert to String
                let value = pair.value.base
                if let stringValue = value as? String {
                    result[pair.key] = stringValue
                } else {
                    // Convert to string representation
                    result[pair.key] = "\(value)"
                }
            }
            finalMetadata.merge(joinMetadataDict) { (_, new) in new }
        }

        // If no metadata from JWT or join message, use guest session metadata when available
        if finalMetadata.isEmpty, metadata == nil, let guestMetadata = guestSession?.metadata {
            finalMetadata = guestMetadata
        }

        // Determine isGuest: true if this is a guest session (no JWT auth and no requested playerID).
        // With a token the join is never a guest, also when it names no playerID.
        let finalIsGuest = (requestedPlayerID == nil && jwtAuthInfo == nil)

        // PlayerSession.init will automatically add isGuest to metadata when isGuest is true
        return PlayerSession(
            playerID: finalPlayerID,
            deviceID: finalDeviceID,
            isGuest: finalIsGuest,
            metadata: finalMetadata
        )
    }

    /// Perform the core join operation: keeper.join, registerSession, and syncStateForNewPlayer.
    /// This is shared logic used by both LandRouter and TransportAdapter.handleJoinRequest.
    ///
    /// - Parameters:
    ///   - playerSession: The PlayerSession to join with
    ///   - clientID: The client ID
    ///   - sessionID: The session ID
    ///   - authInfo: Optional authentication info
    /// - Returns: The final PlayerID if join succeeded, nil if denied
    /// Join result containing the playerID and playerSlot if successful
    public struct JoinResult: Sendable {
        public let playerID: PlayerID
        public let sessionID: SessionID
        /// Deterministic slot (Int32) for efficient transport encoding
        public let playerSlot: Int32
        /// The join completed in a turn (#69): its JoinResponse and firstSync were sent in the
        /// commit of a sync phase, after OnJoin. The caller sends neither. When false, the
        /// caller sends the JoinResponse, then calls `syncStateForNewPlayer`.
        public var completedInTurn: Bool = false
    }

    /// - Parameter connectionGeneration: The transport connection generation read when the
    ///   session's connection was accepted (see `connectionGenerations`); `nil` reads it now.
    ///
    /// - Parameter joinResponse: Builds the JSON JoinResponse frame from the final playerID and
    ///   slot. With it, on the in-turn path (in-turn sync, a live keeper that admits in its join),
    ///   the join completes in a turn (#69): this method returns once the session's JoinResponse
    ///   and firstSync were committed after OnJoin (`completedInTurn`), or throws
    ///   `JoinFlipError`. The membership queue is not held while it waits.
    public func performJoin(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?,
        connectionGeneration: UInt64? = nil,
        joinResponse: (@Sendable (PlayerID, Int32) -> Data?)? = nil,
        joinAttempt: UInt64? = nil
    ) async throws -> JoinResult? {
        guard let result = try await admitJoin(
            playerSession: playerSession,
            clientID: clientID,
            sessionID: sessionID,
            authInfo: authInfo,
            connectionGeneration: connectionGeneration,
            joinResponse: joinResponse,
            joinAttempt: joinAttempt
        ) else { return nil }
        if result.completedInTurn {
            try await awaitJoined(sessionID: sessionID)
        }
        return result
    }

    /// The admission half of `performJoin`: returns once the join is admitted (or denied). A
    /// join that completes in a turn (`completedInTurn`) hasn't flipped yet: await
    /// `awaitJoined(sessionID:)` for that. Until the flip, the session's inbound frames are
    /// deferred, and applied in order after it (#69).
    public func admitJoin(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?,
        connectionGeneration: UInt64? = nil,
        joinResponse: (@Sendable (PlayerID, Int32) -> Data?)? = nil,
        joinAttempt: UInt64? = nil,
        joinDeadline: ContinuousClock.Instant? = nil
    ) async throws -> JoinResult? {
        try await admitJoin(
            playerSession: playerSession,
            clientID: clientID,
            sessionID: sessionID,
            authInfo: authInfo,
            connectionGeneration: connectionGeneration,
            joinResponse: joinResponse,
            joinAttempt: joinAttempt,
            joinDeadline: joinDeadline,
            attemptEnd: nil
        )
    }

    /// `admitJoin`, with the router attempt's `JoinAttemptEnd`: an admission whose attempt the
    /// budget's timeout ended is refused when it runs (#242).
    func admitJoin(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?,
        connectionGeneration: UInt64?,
        joinResponse: (@Sendable (PlayerID, Int32) -> Data?)?,
        joinAttempt: UInt64?,
        joinDeadline: ContinuousClock.Instant?,
        attemptEnd: JoinAttemptEnd?
    ) async throws -> JoinResult? {
        await holds.at(.admitJoinEntry)
        return try await enqueueMembership({
            try await self.performJoinQueued(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: authInfo,
                connectionGeneration: connectionGeneration,
                joinResponse: joinResponse,
                joinAttempt: joinAttempt,
                joinDeadline: joinDeadline,
                attemptEnd: attemptEnd
            )
        })
    }

    private func performJoinQueued(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?,
        connectionGeneration: UInt64?,
        joinResponse: (@Sendable (PlayerID, Int32) -> Data?)?,
        joinAttempt: UInt64?,
        joinDeadline: ContinuousClock.Instant?,
        attemptEnd: JoinAttemptEnd?
    ) async throws -> JoinResult? {
        // A router join that is stale here, in the membership queue's order, isn't admitted:
        // its keeper join would supersede the player's newer session (#97). Checked before the
        // keeper's join, which already changes the keeper's players. So is one whose attempt
        // the budget's timeout ended (#242).
        if attemptEnd?.isEnded == true {
            staleJoinAttemptsRefused += 1
            return nil
        }
        if let joinAttempt, staleJoinAttempt(joinAttempt, sessionID: sessionID, playerID: PlayerID(playerSession.playerID)) {
            staleJoinAttemptsRefused += 1
            return nil
        }
        if let joinAttempt { memberJoinAttempts[sessionID] = joinAttempt }
        // In the segment of the checks above: the keeper's outcome answers the attempt from
        // here, even after the expected admission below is removed (#860).
        attemptEnd?.markKeeperJoinStarted()

        // Attempt to join (updates keeper.players). On the in-turn path the keeper admits the
        // session inside the join, in the segment of its state change (`admitJoiningSession`);
        // otherwise it is admitted below, right after the join returns, before any await.
        expectedAdmissions[sessionID] = ExpectedAdmission(authInfo: authInfo, joinResponse: joinResponse, joinDeadline: joinDeadline, joinAttempt: joinAttempt, attemptEnd: attemptEnd)
        defer { expectedAdmissions.removeValue(forKey: sessionID) }
        let outcome: LandKeeper<State>.JoinOutcome
        do {
            outcome = try await keeper.joinReportingAdmission(
                session: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                services: LandServices(),
                admitThroughTransport: true
            )
        } catch {
            memberJoinAttempts.removeValue(forKey: sessionID)
            abandonJoining(sessionID: sessionID)
            throw error
        }

        // Stale by the player CanJoin resolved (#234): the keeper changed nothing, and nothing
        // was admitted. Answered as the stale refusal above.
        if outcome.refusedStale {
            memberJoinAttempts.removeValue(forKey: sessionID)
            staleJoinAttemptsRefused += 1
            return nil
        }

        switch outcome.decision {
        case .allow(let playerID):
            // Admission: membership, slot and the `.joining` mark (exactly once).
            let slot: Int32
            if outcome.admitted, let joining = joiningSessions[sessionID] {
                slot = joining.playerSlot
            } else {
                slot = admitJoining(sessionID: sessionID, playerID: playerID, authInfo: authInfo)
            }

            let admittedTicket = joiningSessions[sessionID]?.ticket
            let completesInTurn = outcome.admitted && joiningSessions[sessionID]?.inTurn != nil
            if completesInTurn {
                // Admitted and not yet registered with the transport: not ready to flip.
                await holds.at(.keeperJoinReturned)
            }

            // Register session. Already in the membership queue, and the keeper join just ran in
            // it: the internal registration, without the public one's enqueue and keeper check,
            // under the admission's ticket. Nil: no admission record is left for the session
            // here, and nothing is registered. A teardown during the keeper join doesn't make it
            // nil: the admission issues a fresh ticket after that await (#548).
            if let admittedTicket {
                await _registerSessionImpl(
                    sessionID: sessionID,
                    clientID: clientID,
                    playerID: playerID,
                    authInfo: authInfo,
                    acceptedConnectionGeneration: connectionGeneration,
                    ticket: admittedTicket
                )
            }

            if completesInTurn {
                // Ready once registered (and its OnJoin consumed): a land without periodic
                // sync runs the sync phase that flips it; one with it flips at its next sync.
                // Same segment as the check: the record must still be this admission's.
                if let ticket = admittedTicket, joiningSessions[sessionID]?.ticket == ticket {
                    joiningSessions[sessionID]?.inTurn?.transportRegistered = true
                }
                await holds.at(.joinSyncRequested)
                await keeper.requestJoinSyncTurn()
                var result = JoinResult(playerID: playerID, sessionID: sessionID, playerSlot: slot)
                result.completedInTurn = true
                return result
            }

            // NOTE: Initial state snapshot is NOT sent here anymore.
            // The caller should:
            // 1. First send JoinResponse to client
            // 2. Then call syncStateForNewPlayer() to send the state
            // This ensures client knows join succeeded before receiving state.

            return JoinResult(playerID: playerID, sessionID: sessionID, playerSlot: slot)

        case .deny:
            memberJoinAttempts.removeValue(forKey: sessionID)
            return nil
        }
    }

    /// Whether router join `attempt` of `sessionID` is stale in the membership queue's order
    /// (#97): its session's disconnect already ran here, or `playerID`'s member session joined
    /// with a newer attempt. Admitting it would supersede that newer session.
    ///
    /// Checked twice. Before the keeper's join, `playerID` is the requested one. On the in-turn
    /// path the keeper asks again with the player CanJoin resolved (`refusesResolvedJoin`,
    /// #234), so a land that maps players in `CanJoin` is covered too. A join that doesn't run
    /// in the keeper's turn (no attached keeper) checks only the requested player.
    private func staleJoinAttempt(_ attempt: UInt64, sessionID: SessionID, playerID: PlayerID) -> Bool {
        if endedSessions.contains(sessionID) { return true }
        return membershipCoordinator.sessionIDs(for: playerID).contains { member in
            member != sessionID && (memberJoinAttempts[member] ?? 0) > attempt
        }
    }


    /// Inbound ingress: decides where a frame goes, and dispatches it only when its session has
    /// no queue (#69). A joining session's frames are deferred to its flip; a flipped session
    /// whose deferred frames are still draining queues behind them.
    func _onMessageImpl(_ message: Data, from sessionID: SessionID, ackChecked: Bool = false) async {
        profilerCounters?.incrementMessagesReceived()
        profilerCounters?.addBytesReceived(Int64(message.count))
        // A sync ack (#332) is handled at once, also while the session's inbound is deferred or
        // queued: it touches only lag state. The router hands it over before this point.
        if tracksSyncLag, !ackChecked, let seq = SyncAckFrame.parse(message) {
            onSyncAck(seq, from: sessionID)
            return
        }
        if inboundClosedSessions.contains(sessionID) {
            inboundDroppedForJoiningSessions += 1
            return
        }
        if let inTurn = joiningSessions[sessionID]?.inTurn {
            deferInbound(message, from: sessionID, joinFailed: inTurn.failed)
            return
        }
        if inboundAfterFlip[sessionID] != nil {
            queueBehindDrain(message, from: sessionID)
            return
        }
        await dispatchInbound(message, from: sessionID)
    }

    /// A joining session's frame: deferred to its flip, within the bound. Over it, the join
    /// fails with `inboundOverflow`. A failed join's record is terminal: its frames are dropped.
    private func deferInbound(_ message: Data, from sessionID: SessionID, joinFailed: Bool) {
        guard !joinFailed, var joining = joiningSessions[sessionID] else {
            inboundDroppedForJoiningSessions += 1
            return
        }
        let limit = deferredInboundLimit
        if joining.deferredInbound.count + 1 > limit.count || joining.deferredInboundBytes + message.count > limit.bytes {
            inboundDroppedForJoiningSessions += 1
            failInTurnJoin(sessionID: sessionID, reason: .inboundOverflow)
            return
        }
        joining.deferredInbound.append(message)
        joining.deferredInboundBytes += message.count
        joiningSessions[sessionID] = joining
        inboundDeferredForJoiningSessions += 1
    }

    /// A flipped session's frame while its deferred frames drain: queued behind them. Over the
    /// bound the session is closed: it lost an action it sent, so it must reconnect.
    private func queueBehindDrain(_ message: Data, from sessionID: SessionID) {
        guard var drain = inboundAfterFlip[sessionID] else { return }
        let limit = deferredInboundLimit
        if drain.frames.count + 1 > limit.count || drain.bytes + message.count > limit.bytes {
            inboundAfterFlip.removeValue(forKey: sessionID)
            // Terminal in this segment: no later frame of the session is dispatched.
            inboundClosedSessions.insert(sessionID)
            inboundDroppedForJoiningSessions += drain.frames.count + 1
            inboundOverflowClosures += 1
            logger.warning("Closing a session whose inbound frames went over the bound after its join", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "queued": .stringConvertible(drain.frames.count),
            ])
            let error = ErrorPayload(
                code: .inboundOverflow,
                message: "Too many frames were sent while the join completed"
            )
            if let data = try? messageEncoder.encode(TransportMessage.error(error)) {
                sendFinalFrameAndClose(data, kind: messageEncoder.encoding.frameKind, to: sessionID)
            } else {
                let transport = self.transport
                Task { await transport.closeSession(sessionID) }
            }
            return
        }
        drain.frames.append(message)
        drain.bytes += message.count
        inboundAfterFlip[sessionID] = drain
    }

    /// Applies a flipped session's deferred frames one at a time, oldest first (#69). The
    /// entry stays while a dispatch is awaited (it is the active-drain marker); it goes in the
    /// segment that finds the queue empty, or when the session ends (disconnect, supersede,
    /// land teardown), which also drops what it holds.
    private func drainInbound(_ sessionID: SessionID) async {
        while true {
            guard var drain = inboundAfterFlip[sessionID] else { return }
            guard !drain.frames.isEmpty else {
                inboundAfterFlip.removeValue(forKey: sessionID)
                return
            }
            let frame = drain.frames.removeFirst()
            drain.bytes -= frame.count
            inboundAfterFlip[sessionID] = drain
            let ticket = drain.ticket
            await holds.at(.inboundDrainDispatch)
            // A session that ended between the pop and here (the hold point is the step's only
            // suspension): the popped frame isn't dispatched, and is counted as dropped.
            guard sessionTickets.isCurrent(ticket) else {
                inboundDroppedForJoiningSessions += 1
                return
            }
            await dispatchInbound(frame, from: sessionID)
        }
    }

    /// Decodes and routes one inbound frame. Never goes through the ingress, so a drained frame
    /// isn't queued again.
    private func dispatchInbound(_ message: Data, from sessionID: SessionID) async {
        let messageSize = message.count

        // Only compute logging metadata if debug logging is enabled
        if logger.logLevel <= .debug {
        logger.debug("📥 Received message", metadata: [
            "session": .string(sessionID.rawValue),
            "bytes": .string("\(messageSize)")
        ])
        }

        // Log message payload - only compute if trace logging is enabled
        if let messagePreview = logger.safePreview(from: message) {
            logger.trace("📥 Message payload", metadata: [
                "session": .string(sessionID.rawValue),
                "payload": .string(messagePreview)
            ])
        }

        // Compute messagePreview for error logging (only if needed)
        // We compute it lazily in the catch block to avoid unnecessary work
        do {
            // Use decoding pipeline for all message decoding (centralizes format detection)
            let transportMsg: TransportMessage
            let decodeStart = ContinuousClock.now
            
            transportMsg = try decodingPipeline.decode(message)

            if let profiler {
                let decodeElapsed = ContinuousClock.now - decodeStart
                let decodeMs = Double(decodeElapsed.components.seconds) * 1000 + Double(decodeElapsed.components.attoseconds) / 1e15
                latencySampleCounter += 1
                if latencySampleCounter % 100 == 0 {
                    Task { await profiler.recordDecode(durationMs: decodeMs, bytes: messageSize) }
                }
            }

            // Use routing table to dispatch message to appropriate handler
            await routingTable.route(transportMsg, from: sessionID, to: self)
        } catch {
            profilerCounters?.incrementErrors()
            // Compute messagePreview for error logging (only when error occurs)
            let messagePreview = String(data: message, encoding: .utf8) ?? "<non-UTF8 payload>"

            logger.error("❌ Failed to decode message", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)"),
                "payload": .string(messagePreview)
            ])

            // Send error message to client using unified error format
            do {
                let errorPayload = ErrorPayload(
                    code: .invalidJSON,
                    message: "Failed to decode message: \(error)",
                    details: [
                        "sessionID": AnyCodable(sessionID.rawValue),
                        "payloadPreview": AnyCodable(messagePreview)
                    ]
                )
                let errorResponse = TransportMessage.error(errorPayload)
                let errorData = try messageEncoder.encode(errorResponse)
                enqueueOutbound(errorData, to: sessionID, kind: messageEncoder.encoding.frameKind)
            } catch {
                logger.error("❌ Failed to send decode error to client", metadata: [
                    "sessionID": .string(sessionID.rawValue),
                    "error": .string("\(error)")
                ])
            }
        }
    }

    // MARK: - Message Routing Handlers
    
    /// Handle join message (legacy mode only).
    func handleJoinMessage(_ message: TransportMessage, from sessionID: SessionID) async {
        // If legacy join is enabled, handle it directly (for Single Room Mode)
        if enableLegacyJoin {
            if case .join(let payload) = message.payload {
                // Extract landID from payload
                // The payload landID might include "standard:..." prefixes if using new client
                // But for legacy mode we expect the raw ID or we handle validation inside handleJoinRequest
                // Reconstruct landID
                let requestLandID: String
                if let instance = payload.landInstanceId, !instance.isEmpty {
                    requestLandID = "\(payload.landType):\(instance)"
                } else {
                    requestLandID = payload.landType
                }

                await handleJoinRequest(
                    requestID: payload.requestID,
                    landID: requestLandID,
                    sessionID: sessionID,
                    requestedPlayerID: payload.playerID,
                    deviceID: payload.deviceID,
                    metadata: payload.metadata
                )
            }
        } else {
            // Join is now handled by LandRouter
            logger.warning("Received Join message in TransportAdapter (should be handled by Router)", metadata: ["sessionID": .string(sessionID.rawValue)])
        }
    }
    
    /// Handle join response from client (unexpected).
    func handleJoinResponse(from sessionID: SessionID) async {
        // Server should not receive joinResponse from client
        logger.warning("Received joinResponse from client (unexpected)", metadata: [
            "sessionID": .string(sessionID.rawValue)
        ])
    }
    
    /// Handle error message from client (unexpected).
    func handleErrorFromClient(from sessionID: SessionID) async {
        // Server should not receive error from client (errors are server->client)
        logger.warning("Received error message from client (unexpected)", metadata: [
            "sessionID": .string(sessionID.rawValue)
        ])
    }
    
    /// Handle messages that require player to be joined (action, actionResponse, event).
    func handlePlayerMessage(_ message: TransportMessage, from sessionID: SessionID) async {
        // For other messages, require player to be joined.
        // Under load, clients may send (e.g. MoveTo) before join ack is processed; log at debug to avoid noise.
        guard let playerID = membershipCoordinator.playerID(for: sessionID),
              let clientID = membershipCoordinator.clientID(for: sessionID),
              let sessionVersion = membershipCoordinator.currentMembershipStamp(for: sessionID)?.version,
              membershipCoordinator.isSessionCurrent(sessionID, expected: sessionVersion) else {
            if logger.logLevel <= .debug {
                logger.debug("Message received from session that has not joined: \(sessionID.rawValue)")
            }
            return
        }
        
        switch message.kind {
        case .action:
            if case .action(let payload) = message.payload {
                logger.info("📥 Received action", metadata: [
                    "requestID": .string(payload.requestID),
                    "landID": .string(self.landID),
                    "actionType": .string(payload.action.typeIdentifier),
                    "playerID": .string(playerID.rawValue),
                    "sessionID": .string(sessionID.rawValue)
                ])

                // Decode action payload if possible - only compute if trace logging is enabled
                if logger.logLevel <= .trace {
                    // Encode AnyCodable to Data for logging preview
                    if let payloadData = try? JSONEncoder().encode(payload.action.payload),
                       let payloadString = logger.safePreview(from: payloadData) {
                        logger.trace("📥 Action payload", metadata: [
                            "requestID": .string(payload.requestID),
                            "payload": .string(payloadString)
                        ])
                    }
                }

                // Handle action request
                // Use self.landID instead of payload.landID (server identifies land from session mapping)
                await handleActionRequest(
                    requestID: payload.requestID,
                    envelope: payload.action,
                    playerID: playerID,
                    clientID: clientID,
                    sessionID: sessionID
                )
            }

        case .actionResponse:
            if case .actionResponse(let payload) = message.payload {
                logger.info("📥 Received action response", metadata: [
                    "requestID": .string(payload.requestID),
                    "playerID": .string(playerID.rawValue),
                    "sessionID": .string(sessionID.rawValue)
                ])

                // Log response payload - only compute if trace logging is enabled
                if logger.logLevel <= .trace {
                    if let responseData = try? codec.encode(payload.response),
                       let responseString = logger.safePreview(from: responseData) {
                        logger.trace("📥 Response payload", metadata: [
                            "requestID": .string(payload.requestID),
                            "response": .string(responseString)
                        ])
                    }
                }
            }

        case .event:
            if case .event(let event) = message.payload {
                if case .fromClient(let anyClientEvent) = event {
                    logger.info("📥 Received client event", metadata: [
                        "landID": .string(self.landID),
                        "eventType": .string(anyClientEvent.type),
                        "playerID": .string(playerID.rawValue),
                        "sessionID": .string(sessionID.rawValue)
                    ])

                    // Log event payload - only compute if trace logging is enabled
                    if logger.logLevel <= .trace {
                        if let payloadData = try? codec.encode(anyClientEvent.payload),
                           let payloadString = logger.safePreview(from: payloadData) {
                            logger.trace("📥 Event payload", metadata: [
                                "eventType": .string(anyClientEvent.type),
                                "payload": .string(payloadString)
                            ])
                        }
                    }

                    do {
                        try await keeper.handleClientEvent(
                            anyClientEvent,
                            playerID: playerID,
                            clientID: clientID,
                            sessionID: sessionID
                        )
                    } catch let rejection as LandInputRejection {
                        // Expected, not a handler error: the land is closing (an event still
                        // queued at teardown, or one sent while it drains) or a newer join
                        // replaced this session. Either way the session is going away, and an
                        // event has no reply to fail, so no error frame is sent.
                        logger.debug("Client event rejected", metadata: [
                            "eventType": .string(anyClientEvent.type),
                            "playerID": .string(playerID.rawValue),
                            "sessionID": .string(sessionID.rawValue),
                            "rejection": .string("\(rejection)")
                        ])
                    } catch {
                        // Handle event processing errors
                        logger.error("❌ Event handler error", metadata: [
                            "eventType": .string(anyClientEvent.type),
                            "playerID": .string(playerID.rawValue),
                            "sessionID": .string(sessionID.rawValue),
                            "error": .string("\(error)")
                        ])

                        // Determine error code
                        let errorCode: ErrorCode
                        let errorMessage: String

                        if let payloadError = error as? ClientEventPayloadError {
                            // Refused at intake, before a handler ran (#537).
                            errorCode = .eventInvalidPayload
                            errorMessage = "\(payloadError)"
                        } else if let resolverError = error as? ResolverExecutionError {
                            errorCode = .eventHandlerError
                            errorMessage = "Event handler failed: \(resolverError)"
                        } else if let resolverError = error as? ResolverError {
                            errorCode = .eventHandlerError
                            errorMessage = "Event handler failed: \(resolverError)"
                        } else {
                            errorCode = .eventHandlerError
                            errorMessage = "Event handler error: \(error)"
                        }

                        // Send error to client
                        let errorPayload = ErrorPayload(
                            code: errorCode,
                            message: errorMessage,
                            details: [
                                "eventType": AnyCodable(anyClientEvent.type),
                                "landID": AnyCodable(landID)
                            ]
                        )
                        let errorResponse = TransportMessage.error(errorPayload)
                        if let errorData = try? messageEncoder.encode(errorResponse) {
                            enqueueOutbound(errorData, to: sessionID, kind: messageEncoder.encoding.frameKind)
                        }
                    }
                } else if case .fromServer = event {
                    logger.warning("Received server event from client (unexpected)", metadata: [
                        "sessionID": .string(sessionID.rawValue)
                    ])
                }
            }

        case .join, .joinResponse, .error:
            // Already handled in main routing
            break
        }
    }

    // MARK: - Helper Methods

    /// Send server event to specified target. When opcode 107 is enabled (opcodeMessagePack) and
    /// messages are MessagePack, events are queued and sent merged with the next state update
    /// instead of separate frames.
    ///
    /// **Hybrid configurations** (`message: .json` or `.opcodeJsonArray` with `stateUpdate:
    /// .opcodeMessagePack`, e.g. debugging or migration): opcode 107 merges events as MessagePack
    /// values, which only a MessagePack message encoder produces. So every event goes as its own
    /// frame. That is decided once at init (`eventsMerge`, #521 D10), with no body attempt.
    ///
    /// **With MessagePack messages,** an event whose body doesn't encode is lost (its own frame
    /// would fail the same way: one encoder, one conversion), which ends the land (#535 row 17).
    public func sendEvent(_ event: AnyServerEvent, to target: SwiftStateTree.EventTarget) async {
        guard enqueueEventSynchronously(event, to: target) == .lost else { return }
        // An event that reached no frame ends the land (#535 row 17).
        let failure = LandFailure(
            kind: .eventEncode,
            detail: "event \(event.type) did not encode",
            position: LandFailurePosition(stage: .eventFlush)
        )
        await failOutsideTurn(failure)
    }

    /// The synchronous core of `sendEvent`: opcode 107 queues the event body for the next merged
    /// frame; otherwise the event is encoded and enqueued to the outbound writer now, so events
    /// reach the writer in the order they are passed here.
    ///
    /// Returns where the event went.
    @discardableResult
    func enqueueEventSynchronously(
        _ event: AnyServerEvent,
        to target: SwiftStateTree.EventTarget,
        digest: CanonicalSyncEvent? = nil
    ) -> EventEnqueueOutcome {
        // A held event that took a joiner over the bound fails its join once the emit is done,
        // never inside the target resolution (#69).
        defer {
            if !heldEventOverflows.isEmpty { failHeldEventOverflows() }
        }
        let fault = eventEncodingFaultForTesting?(event.type)
        // Queue mode (opcode 107, MessagePack messages)
        if eventsMerge {
            // A body that doesn't encode means a frame that wouldn't either (one encoder, one
            // conversion): the event is lost after one encode, with no second attempt (#521 D10).
            let body: MessagePackValue
            do {
                if fault == .all {
                    throw EncodingError.invalidValue(event.type, .init(codingPath: [], debugDescription: "encoding fault (tests)"))
                }
                body = try encodingPipeline.encodeServerEventBodyOrThrow(event)
            } catch {
                logger.error("❌ Event did not encode; it is lost", metadata: [
                    "eventType": .string(event.type),
                    "error": .string("\(error)")
                ])
                return .lost
            }
            let queued = eventSendingPipeline.queueForMergedSend(
                eventBody: body,
                target: target,
                pendingEventManager: &pendingEventManager,
                membershipCoordinator: membershipCoordinator,
                digest: digest
            )
            return queued ? .queued : .noRecipient
        }
        // Hybrid (opcode 107, messages not MessagePack): no body can merge, so the event goes as
        // its own frame, decided at init (#521 D10).
        if useStateUpdateWithEvents {
            return sendEventImmediately(event, to: target, failsEncoding: fault == .all) ? .sentAlone : .lost
        }

        // Immediate mode: encoded and enqueued now. An event that doesn't encode is lost, which
        // ends the land (#535 row 17); a stale or invalid target isn't a loss.
        return sendEventImmediately(event, to: target, failsEncoding: fault == .all) ? .immediate : .lost
    }

    /// Where `enqueueEventSynchronously` put an event.
    enum EventEnqueueOutcome: Equatable {
        /// Queued for the next merged frame (opcode 107).
        case queued
        /// Opcode 107, and nothing to queue: no recipient (`.players([])`, a client without a
        /// session).
        case noRecipient
        /// Opcode 107 in a hybrid configuration (messages not MessagePack): sent as its own frame,
        /// or nothing to send (a stale target).
        case sentAlone
        /// The event did not encode: with opcode 107 and MessagePack messages its body, otherwise
        /// its own frame. Lost, so the land ends (#535 row 17).
        case lost
        /// Not opcode 107: sent as its own frame.
        case immediate
    }

    // MARK: - In-turn sync phase

    /// The isolated body of `runSyncPhaseInTurn`, run inside the keeper's turn on the shared
    /// executor. Never suspends.
    ///
    /// Enqueues `events` in order, then (if `includeSync`) plans and commits a full sync phase on
    /// `state`, whose frames go to the writer after those events.
    ///
    /// Back-pressure (`writerHoldsEarlierElementForInTurnSync`) is checked before anything is
    /// planned: `.deferredBackPressure`, and opcode 107 events stay queued for the next phase.
    ///
    /// Opcode 107 order limit (inherited from the sync phase plan): per session the merged
    /// broadcast frame comes first, then the targeted event frames, then the per-player frame. The
    /// emit order holds within each frame kind; a targeted event emitted before a broadcast event
    /// of the same turn reaches its client after it.
    ///
    /// A plan that throws ends the land (#535 row 15): `.landFailed`, and the keeper ends it in
    /// the same turn.
    ///
    /// `recording` is the keeper's (#553): with it, the phase's sync-stream entries (the
    /// resync clears, the output, the seeds) are returned as drafts, in order, whatever the
    /// result; the keeper numbers and submits them.
    func runSyncPhaseInTurnIsolated<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording? = nil
    ) -> InTurnSyncOutput {
        assert(inTurnSyncStreamDrafts.isEmpty, "sync-stream drafts left from an earlier phase")
        let result = runSyncPhaseInTurnResult(state: state, events: events, includeSync: includeSync, recording: recording)
        let drafts = inTurnSyncStreamDrafts
        inTurnSyncStreamDrafts = []
        // Events still queued after a commit (kept by it, or queued after it): the keeper asks
        // for one more sync-only turn on a land without periodic sync.
        var keepsEvents = false
        if case .committed = result { keepsEvents = pendingEventManager.hasAnyEvents }
        return InTurnSyncOutput(result, syncStream: drafts, keepsEvents: keepsEvents)
    }

    private func runSyncPhaseInTurnResult<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncResult {
        let digestsEvents = useStateUpdateWithEvents && !events.isEmpty && recording != nil
        for item in events {
            let digest = digestsEvents ? SyncStreamCanonical.canonicalEvent(item) : nil
            let outcome = enqueueEventSynchronously(item.event, to: item.target, digest: digest)
            if outcome == .lost {
                // An event that reached no frame ends the land (#535 row 17). One sent alone
                // (a hybrid configuration) isn't a loss.
                let failure = LandFailure(
                    kind: .eventEncode,
                    detail: "event \(item.event.type) did not encode",
                    position: LandFailurePosition(stage: .syncPhase)
                )
                outputGate.close(failure)
                return .landFailed(failure)
            }
            if digestsEvents, let sequence = item.sequence {
                switch outcome {
                case .noRecipient: syncStreamUnqueuedEvents.append(sequence)
                case .sentAlone: syncStreamUnmergedEvents.sentAlone.append(sequence)
                case .lost: syncStreamUnmergedEvents.lost.append(sequence)
                case .queued, .immediate: break
                }
            }
        }
        guard includeSync else { return .notRequested }
        // After teardown nothing is sent any more.
        guard !outboundWriter.isFinished else { return .skipped }
        // The freeze first (#546 L2a): a frozen phase always leaves its sync to the resume, also
        // while the writer still holds the settle's frames.
        if debugDeferSyncIfFrozen() { return .skipped }
        if writerHoldsEarlierElementForInTurnSync() {
            syncSkips.outboundBacklog += 1
            profilerCounters?.incrementSyncSkipsBacklog()
            profilerCounters?.incrementSyncDeferredTurns()
            return .deferredBackPressure
        }
        profilerCounters?.setSessionCounts(
            connected: membershipCoordinator.connectedSessions.count,
            joined: membershipCoordinator.joinedCount()
        )
        guard !membershipCoordinator.isEmpty else { return .skipped }
        guard let state = state as? State else {
            preconditionFailure("runSyncPhaseInTurn called with a state of another land type")
        }
        // Read once: `setDirtyTrackingEnabled` may change `enableDirtyTracking` while the phase runs.
        let clearDirtyFlags = enableDirtyTracking
        let joiners = readyInTurnJoins(limit: joinFlipBudgetForTesting ?? JoinFlipConfig.budget).map { entry in
            SyncPhaseJoiner(
                recipient: SyncPhaseRecipient(sessionID: entry.sessionID, playerID: entry.joining.playerID),
                ticket: entry.joining.ticket,
                joinResponse: entry.joining.inTurn?.joinResponse ?? Data()
            )
        }
        do {
            let read = recording.map { SyncOutputRead(turnKind: $0.turnKind, position: $0.position) }
            try runFullSyncPhase(state: state, read: read, joiners: joiners)
            return .committed(clearDirtyFlags: clearDirtyFlags)
        } catch {
            logger.error("Sync operation failed", metadata: [
                "message": .string("❌ In-turn sync phase failed"),
                "error": .string("\(error)")
            ])
            // The first throw ends the land (#535 row 15): the plan committed and sent nothing.
            // A frame that didn't encode (rows 9, 10, 12) arrives as its own `LandFailure`.
            return .landFailed(error as? LandFailure ?? LandFailure(
                kind: .syncPlan,
                detail: String(describing: error),
                position: LandFailurePosition(stage: .syncPhase)
            ))
        }
    }
    
    /// `sessionIDs` without the sessions sync-lag tracking holds pending (#332): an event sent at
    /// emit (the encodings without merged frames) is dropped and counted for them, as the plan
    /// drops the ones it consumes.
    private func withoutPendingSyncLag(_ sessionIDs: [SessionID]) -> [SessionID] {
        guard tracksSyncLag, !syncLag.isEmpty else { return sessionIDs }
        var dropped = 0
        let kept = sessionIDs.filter { sessionID in
            guard syncLag[sessionID]?.dropsEvents == true else { return true }
            dropped += 1
            return false
        }
        if dropped > 0 {
            syncLagDroppedEvents += dropped
            syncLagProfilerCounters?.addSyncLag(.init(droppedEvents: dropped))
        }
        return kept
    }

    /// Send event immediately (encode and transport.send).
    ///
    /// The path for every event when opcode 107 is disabled, and in a hybrid configuration (opcode
    /// 107 with `json` or `opcodeJsonArray` messages, decided at init, #521 D10).
    /// Handles encoding, validation, logging, and actual transport.send call.
    /// Returns false when the event did not encode (it is lost); true otherwise, also when its
    /// target has no current recipient.
    @discardableResult
    private func sendEventImmediately(
        _ event: AnyServerEvent,
        to target: SwiftStateTree.EventTarget,
        failsEncoding: Bool = false
    ) -> Bool {
        do {
            if failsEncoding {
                throw EncodingError.invalidValue(event.type, .init(codingPath: [], debugDescription: "encoding fault (tests)"))
            }
            guard let decision = try eventSendingPipeline.prepareImmediateSend(
                event: event,
                target: target,
                membershipCoordinator: membershipCoordinator
            ) else {
                return true  // Target is invalid or stale
            }
            
            guard case .immediate(let data, let transportTarget, let targetDescription) = decision else {
                logger.warning("⚠️ Unexpected queued decision in immediate mode")
                return true
            }
            
            let dataSize = data.count
            
            // Special case: multiple players (send to each session individually)
            if case .players(let playerIDs) = target {
                let playerIDsString = playerIDs.map { $0.rawValue }.joined(separator: ", ")
                logger.info("📤 Sending event to multiple players", metadata: [
                    "eventType": .string(event.type),
                    "playerIDs": .string(playerIDsString),
                    "bytes": .string("\(dataSize)")
                ])

                for playerID in playerIDs {
                    guard let stamp = membershipCoordinator.currentMembershipStamp(for: playerID),
                          membershipCoordinator.isPlayerCurrent(playerID, expected: stamp.version) else {
                        continue
                    }
                    // The filtered expansion: a joining session gets no `.players` event either.
                    guard !outputGate.isClosed else { continue }
                    let frame = EncodedFrame(data: data, kind: messageEncoder.encoding.frameKind)
                    enqueueOutbound(data, kind: frame.kind, toSessions: withoutPendingSyncLag(sessionIDs(for: .player(playerID), holding: frame)))
                }
                return true
            }
            
            // Standard case: single target
            logger.info("📤 Sending server event", metadata: [
                "eventType": .string(event.type),
                "target": .string(targetDescription),
                "landID": .string(landID),
                "bytes": .string("\(dataSize)"),
                "encoding": .string("\(messageEncoder.encoding.rawValue)")
            ])
            
            // Debug: Log actual data size breakdown for trace level
            if logger.logLevel <= .trace {
                let hexPreview = HexEncoding.lowercaseHexString(data, separator: " ")
                logger.trace("📤 Event data breakdown", metadata: [
                    "eventType": .string(event.type),
                    "totalBytes": .string("\(dataSize)"),
                    "hexPreview": .string(hexPreview),
                    "encoding": .string("\(messageEncoder.encoding.rawValue)")
                ])
            }

            // Log event payload - only compute if trace logging is enabled
            if logger.logLevel <= .trace {
                if let payloadData = try? codec.encode(event.payload),
                   let payloadString = logger.safePreview(from: payloadData) {
                    logger.trace("📤 Event payload", metadata: [
                        "eventType": .string(event.type),
                        "target": .string(targetDescription),
                        "payload": .string(payloadString)
                    ])
                }
            }

            // Expanded to this land's sessions (#84): the transport is shared by every land
            // of the type, so its `.broadcast` and player map reach other lands' sessions.
            guard !outputGate.isClosed else { return true }
            let frame = EncodedFrame(data: data, kind: messageEncoder.encoding.frameKind)
            enqueueOutbound(data, kind: frame.kind, toSessions: withoutPendingSyncLag(sessionIDs(for: transportTarget, holding: frame)))
            return true
        } catch {
            logger.error("❌ Failed to send event", metadata: [
                "eventType": .string(event.type),
                "error": .string("\(error)")
            ])
            return false
        }
    }

    private func enqueueMembership<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = membershipQueueTail
        let task: Task<T, Error> = Task {
            await self.holds.at(.membershipQueued)
            if let previous { _ = await previous.result }
            return try await operation()
        }
        membershipQueueTail = Task { _ = await task.result }
        return try await task.value
    }

    /// Encoded targeted event bodies in `events` for a given client (sessionID + playerID).
    ///
    /// - Parameter endIndex: Stop before this index (the count the plan read).
    private func pendingTargetedEventBodies(
        events: PendingEventManager,
        for sessionID: SessionID,
        playerID: PlayerID,
        endingBefore endIndex: Int
    ) -> [MessagePackValue] {
        let clientID = membershipCoordinator.clientID(for: sessionID)
        return events.pendingTargetedBodies(
            for: sessionID,
            playerID: playerID,
            clientID: clientID,
            isSessionCurrent: { sessionID, version in
                membershipCoordinator.isSessionCurrent(sessionID, expected: version)
            },
            isPlayerCurrent: { playerID, version in
                membershipCoordinator.isPlayerCurrent(playerID, expected: version)
            },
            endingBefore: endIndex
        )
    }


    /// Appends one event frame (opcode 103) per body for `sessionID`. A frame that doesn't
    /// pack ends the land (#535 row 17): the event would be lost.
    private func appendEventFrames(
        _ eventBodies: [MessagePackValue],
        to sessionID: SessionID,
        into frames: inout [SyncPhaseFrame]
    ) throws {
        for body in eventBodies {
            // A body that isn't an array is skipped before the fault hook, as it always was.
            guard case .array = body else { continue }
            do {
                if let fault = eventFramePackFaultForTesting, fault(sessionID) {
                    throw SyncPhaseInjectedEncodeFault()
                }
                guard let data = try encodingPipeline.packEventFrame(body) else { continue }
                // MessagePack (`packEventFrame`): binary.
                frames.append(SyncPhaseFrame(data: data, sessionID: sessionID, kind: .binary))
            } catch {
                throw LandFailure(
                    kind: .eventEncode,
                    detail: "event frame: \(error)",
                    position: LandFailurePosition(stage: .syncPhase)
                )
            }
        }
    }

    /// Trigger immediate state synchronization
    ///
    /// NOTE: Parallel sync optimization was tested but did not show performance improvements.
    /// Benchmark results showed that TaskGroup overhead and actor isolation costs exceeded
    /// the benefits of parallel diff computation, even with 50+ players. The serial version
    /// remains simpler and performs equally well or better in practice.
    ///
    /// Future optimization opportunities:
    /// - Batch per-player snapshot extraction for multiple players
    /// - Cache per-player snapshots if state hasn't changed
    /// - Consider incremental sync for large state trees
    func _syncNowImpl() async {
        // One sync-only turn on the keeper, now (#546 L2a).
        _ = await keeper.syncTurnNow(via: self, reason: .syncNow)
    }

    /// Starts `body` as a background sync Task and keeps its handle until it finishes.
    private func startBackgroundSync(_ body: @escaping @Sendable (TransportAdapter) async -> Void) {
        let id = nextBackgroundSyncTaskID
        nextBackgroundSyncTaskID += 1
        // The Task runs on this actor after this turn, so the handle is stored before it ends.
        backgroundSyncTasks[id] = Task {
            await body(self)
            self.backgroundSyncTasks[id] = nil
        }
    }

    /// Tests: returns once no background sync task is left (the delayed repair, or the lag
    /// timer's request) and the keeper has no requested sync work pending (a writer-drain
    /// retry, a join-sync turn, a requested turn after a turn). The
    /// differential harness runs with its loops off and awaits this after each sync it asks for,
    /// so a skipped or deferred phase's retry is part of that step. Also returns when its task is
    /// cancelled (a test bounds it with `withinHangBound`).
    package func waitForBackgroundSyncsForTesting() async {
        while !Task.isCancelled {
            if let task = backgroundSyncTasks.values.first {
                await waitCancellablyForTesting(task)
                continue
            }
            if await keeper.hasRequestedSyncWorkForTesting {
                await keeper.waitForRequestedSyncTurnsForTesting()
                continue
            }
            return
        }
    }

    /// Tests: awaits `task`, or returns early when the caller's task is cancelled (awaiting an
    /// unstructured task's value alone doesn't end on cancellation).
    private func waitCancellablyForTesting(_ task: Task<Void, Never>) async {
        let once = TestingResumeOnce()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.install(continuation)
                Task {
                    await task.value
                    once.resume()
                }
            }
        } onCancel: {
            once.resume()
        }
    }

    /// One requested sync-only turn on the keeper, through this adapter (in-turn only).
    func requestSyncTurn(reason: SyncTurnReason) async -> InTurnSyncResult {
        await keeper.syncTurnNow(via: self, reason: reason)
    }

    /// Tests: the keeper's requested sync work (`LandKeeper.waitForRequestedSyncTurnsForTesting`).
    func keeperHasRequestedSyncWorkForTesting() async -> Bool {
        await keeper.hasRequestedSyncWorkForTesting
    }

    func waitForKeeperRequestedSyncWorkForTesting() async {
        await keeper.waitForRequestedSyncTurnsForTesting()
    }

    private func startDelayedFollowUpSync() {
        startBackgroundSync { adapter in
            // The ticket is taken before the delay, so a repair armed under an older binding
            // retires without a turn.
            let ticket = await adapter.keeper.syncTurnTicket(via: adapter)
            try? await safeTaskSleep(for: Self.syncFailedPlanFollowUpDelay)
            await adapter.holds.at(.failedPlanFollowUp)
            guard let ticket else { return }
            _ = await adapter.keeper.syncTurnNow(via: adapter, reason: .behindCommitRepair, ticket: ticket)
        }
    }

    /// Sync cycles skipped so far (tests and diagnostics, such as a benchmark checking that every
    /// cycle it requested ran). Not a supported API.
    @_spi(Diagnostics) public func syncSkipCounts() -> SyncSkipCounts {
        syncSkips
    }

    /// The frame prefix cache's counts so far, for this adapter's opcode encoder (zero for
    /// another encoder): diagnostics, such as a benchmark reporting cache hits with the cache on
    /// (#392). The counts include every frame, warm-up and joins too; a caller that wants a
    /// window takes the difference of two reads. Not a supported API.
    @_spi(Diagnostics) public func framePrefixCacheCounts() -> FramePrefixCacheCounts {
        let cache: FramePrefixCache?
        if let encoder = stateUpdateEncoder as? OpcodeJSONStateUpdateEncoder {
            cache = encoder.framePrefixCache
        } else if let encoder = stateUpdateEncoder as? OpcodeMessagePackStateUpdateEncoder {
            cache = encoder.framePrefixCache
        } else {
            cache = nil
        }
        guard let cache else { return FramePrefixCacheCounts() }
        return FramePrefixCacheCounts(resumes: cache.resumes, reusedSplits: cache.reusedSplits)
    }

    // MARK: - Sync lag (#332)

    /// Replaces the lag clock (tests).
    package func setSyncLagClockForTesting(_ now: (@Sendable () -> ContinuousClock.Instant)?) {
        syncLagNowForTesting = now
    }

    /// Sync-lag profile counters of the test's own, apart from the shared profiler's window.
    package func setSyncLagProfilerCountersForTesting(_ counters: TransportProfilerCounters) {
        syncLagProfilerCounters = counters
    }

    /// Shortens the lag timer's period (tests); applies to a timer started after it.
    package func setSyncLagTimerIntervalForTesting(_ interval: Duration) {
        syncLagTimerInterval = interval
    }

    /// The lag clock's now, as the lag state stores it (`TurnInstant`, so it is plain data).
    private func syncLagNow() -> TurnInstant {
        TurnInstant(syncLagNowForTesting?() ?? .now)
    }

    /// The plan's first step (D1): classifies each recipient with its lag state and returns the
    /// recipients the plan sends to. A pending session, newly or still, and one with a close due
    /// are left out (no frames, no events). A resync due is planned in the full plan (the player
    /// as an unsynced recipient, its view typed a resync, every session of the player with it).
    /// Only the commit writes what it decided.
    private func classifySyncLag(
        _ recipients: [SyncPhaseRecipient],
        events: PendingEventManager,
        into plan: inout SyncPhasePlan
    ) -> [SyncPhaseRecipient] {
        guard tracksSyncLag, !syncLag.isEmpty else { return recipients }
        let now = syncLagNow()
        var kept: [SyncPhaseRecipient] = []
        kept.reserveCapacity(recipients.count)
        var resyncPlayers = Set<PlayerID>()
        for recipient in recipients {
            guard let session = syncLag[recipient.sessionID], !endedSessions.contains(recipient.sessionID) else {
                kept.append(recipient)
                continue
            }
            switch session.decide(now: now, policy: syncLagPolicy) {
            case .none:
                if session.plansFrames { kept.append(recipient) }
            case .markPending:
                plan.syncLag.markPending.append(recipient.sessionID)
            case .resync:
                plan.syncLag.resyncs[recipient.sessionID] = true
                resyncPlayers.insert(recipient.playerID)
                kept.append(recipient)
            case .close(let code):
                plan.syncLag.closes.append((recipient.sessionID, code))
            }
        }
        if !resyncPlayers.isEmpty {
            for recipient in kept where resyncPlayers.contains(recipient.playerID) && plan.syncLag.resyncs[recipient.sessionID] == nil {
                plan.syncLag.resyncs[recipient.sessionID] = false
            }
        }
        plan.syncLag.resyncPlayers = resyncPlayers
        plan.digest?.resyncPlayers = resyncPlayers
        if plan.digest != nil, kept.count != recipients.count {
            // A player none of whose sessions is kept gets nothing from this plan (#572).
            let keptPlayers = Set(kept.map(\.playerID))
            plan.digest?.withheldPlayers = Set(recipients.map(\.playerID)).subtracting(keptPlayers)
        }
        planResyncPlayers = resyncPlayers
        // The events this plan consumes for a session it leaves out are lost to that session:
        // counted (its targeted ones and its share of the broadcast ones).
        if useStateUpdateWithEvents && kept.count != recipients.count {
            let keptSessions = Set(kept.map(\.sessionID))
            for recipient in recipients where !keptSessions.contains(recipient.sessionID) {
                plan.syncLag.droppedEvents += events.broadcastEventCount + pendingTargetedEventBodies(
                    events: events, for: recipient.sessionID, playerID: recipient.playerID,
                    endingBefore: events.targetedEventCount
                ).count
            }
        }
        return kept
    }

    /// A sync ack from the session (#332): synchronous, and it touches only the session's lag
    /// state. A session with none (joining, its firstSync not committed, ended or closing) drops
    /// it, and nothing is created by key. Each ack costs a lookup plus the entries it pops, no
    /// more than any other inbound message; nothing bounds a client's ack rate separately.
    func onSyncAck(_ seq: UInt64, from sessionID: SessionID) {
        guard tracksSyncLag, !endedSessions.contains(sessionID), syncLag[sessionID] != nil else {
            syncLagDroppedAcks += 1
            syncLagProfilerCounters?.addSyncLag(.init(droppedAcks: 1))
            return
        }
        syncLag[sessionID]?.ack(seq, at: syncLagNow())
    }

    /// A session's firstSync committed with `plan`: its lag tracking starts.
    private func startSyncLagTracking(_ sessionID: SessionID, plan: SyncPhasePlan) {
        guard let seq = plan.syncSeq, !outboundWriter.isFinished else { return }
        syncLag[sessionID] = SyncLagSession(firstSyncSeq: seq, committedAt: syncLagNow())
        startSyncLagTimerIfNeeded()
    }

    /// Starts the timer when none runs. Its loop sleeps outside any state, then runs one
    /// synchronous pass, which also decides whether the loop goes on: no `await` sits between
    /// what the pass reads and what it does.
    private func startSyncLagTimerIfNeeded() {
        guard syncLagTimer == nil, !syncLagPolicy.decisionsOff else { return }
        syncLagTimerEpoch += 1
        let epoch = syncLagTimerEpoch
        let interval = syncLagTimerInterval
        syncLagTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await safeTaskSleep(for: interval)
                guard let self, await self.syncLagTimerPass(epoch: epoch) else { return }
            }
        }
    }

    // MARK: - Named test observations (#555)

    /// Tests: one join attempt, by its session and the router's attempt number (nil for a join
    /// that didn't come through the router).
    package struct JoinAttemptKey: Hashable, Sendable {
        package let sessionID: SessionID
        package let attempt: UInt64?

        package init(sessionID: SessionID, attempt: UInt64?) {
            self.sessionID = sessionID
            self.attempt = attempt
        }
    }

    #if DEBUG
    /// Join attempts whose in-turn flip a sync phase committed.
    private var joinFlipsCommitted: Set<JoinAttemptKey> = []
    /// Join attempts whose initial sync a sync phase committed: an in-turn flip, the standalone
    /// firstSync of a join without in-turn sync, or the full view a cycle sends an unsynced
    /// recipient whose firstSync was dropped behind a commit (#564).
    private var initialSyncsCommitted: Set<JoinAttemptKey> = []
    /// Off until a test opts in, so a debug server keeps no key per join.
    private var capturesJoinCommits = false

    /// Recorded in the commit's segment, so a test reads it at any later checkpoint.
    private func noteJoinCommitForTesting(_ sessionID: SessionID, flipped: Bool) {
        guard capturesJoinCommits else { return }
        let key = JoinAttemptKey(sessionID: sessionID, attempt: memberJoinAttempts[sessionID])
        if flipped { joinFlipsCommitted.insert(key) }
        initialSyncsCommitted.insert(key)
    }
    #endif

    /// Tests: starts recording the join commits `joinFlippedForTesting` and
    /// `initialSyncCommittedForTesting` read. Before it, both read false. DEBUG builds only.
    package func captureJoinCommitsForTesting() {
        #if DEBUG
        capturesJoinCommits = true
        #endif
    }

    /// Tests: the attempt's in-turn flip committed. Unlike the join's waiter, this can't read as
    /// success for a join that never flipped: it is recorded only by the commit.
    package func joinFlippedForTesting(_ key: JoinAttemptKey) -> Bool {
        #if DEBUG
        return joinFlipsCommitted.contains(key)
        #else
        return false
        #endif
    }

    /// Tests: the attempt's initial sync committed.
    package func initialSyncCommittedForTesting(_ key: JoinAttemptKey) -> Bool {
        #if DEBUG
        return initialSyncsCommitted.contains(key)
        #else
        return false
        #endif
    }

    /// Tests: the keeper admitted the session's in-turn join and the adapter holds the
    /// admission, but the session isn't registered with the transport yet: neither the adapter's
    /// record nor, over a `WebSocketTransport`, the transport's player table has it.
    package func admittedNotRegisteredForTesting(_ sessionID: SessionID) async -> Bool {
        guard let joining = joiningSessions[sessionID], let inTurn = joining.inTurn,
              !inTurn.transportRegistered else { return false }
        guard let webSocket = transport as? WebSocketTransport else { return true }
        let registered = await webSocket.playerSessionsForTesting(joining.playerID).contains(sessionID)
        // Re-read after the await: the join may have registered meanwhile.
        return !registered && joiningSessions[sessionID]?.inTurn?.transportRegistered == false
    }

    /// Tests: whether the adapter still holds a join attempt's bookkeeping for the session: its
    /// expected admission, and its member join attempt.
    package func joinBookkeepingForTesting(_ sessionID: SessionID) -> (expectedAdmission: Bool, memberJoinAttempt: Bool) {
        (expectedAdmissions[sessionID] != nil, memberJoinAttempts[sessionID] != nil)
    }

    /// Tests: an opaque token for the session's current membership ticket, nil when it has none.
    package func sessionTicketForTesting(_ sessionID: SessionID) -> Ticket<SessionID>? {
        sessionTickets.ticket(for: sessionID)
    }

    /// Tests: whether that same ticket is still current.
    package func ticketIsCurrentForTesting(_ ticket: Ticket<SessionID>) -> Bool {
        sessionTickets.isCurrent(ticket)
    }

    /// Tests: the session's pending action jobs whose answers the adapter still tracks.
    package func pendingActionCountForTesting(_ sessionID: SessionID) -> Int {
        actionResponseTasks[sessionID]?.count ?? 0
    }

    /// Tests: whether the lag timer is running.
    var syncLagTimerRunningForTesting: Bool { syncLagTimer != nil }

    /// Stops the timer (teardown).
    func stopSyncLagTimer() {
        syncLagTimer?.cancel()
        syncLagTimer = nil
        syncLagTimerEpoch += 1
    }

    /// One timer pass, synchronous. Returns whether the timer goes on. It decides with the same
    /// function as the plan and applies only closes; a pending mark or a resync due on a land
    /// without periodic sync requests one sync, whose plan classifies again. Nothing due, nothing
    /// happens: an idle land with empty FIFOs gets no turn from it.
    private func syncLagTimerPass(epoch: UInt64) -> Bool {
        guard epoch == syncLagTimerEpoch else { return false }
        guard !syncLag.isEmpty, !outboundWriter.isFinished else {
            syncLagTimer = nil
            return false
        }
        let now = syncLagNow()
        var wantsSync = false
        // A session already ended (a writer-ceiling drop, a 4008) waits for its disconnect.
        for (sessionID, session) in syncLag where !endedSessions.contains(sessionID) {
            switch session.decide(now: now, policy: syncLagPolicy) {
            case .none:
                continue
            case .close(let code):
                closeLaggingSession(sessionID, code: code)
            case .markPending, .resync:
                wantsSync = true
            }
        }
        // The mark is the epoch of the pass that set it: a pass of a newer epoch requests even
        // while an older callback is held, and a stale callback clears only its own mark.
        if wantsSync, !keeper.hasPeriodicSync, syncLagTimerSyncRequestedEpoch != epoch {
            syncLagTimerSyncRequestedEpoch = epoch
            syncLagTimerSyncRequests += 1
            startBackgroundSync { adapter in
                await adapter.runSyncLagTimerSync(epoch: epoch)
            }
        }
        return true
    }

    /// One timer pass now, as the timer would run it (tests drive the passes by hand). A sync it
    /// requests runs in a background task: `waitForSyncQuiescenceForTesting()` waits for it, and
    /// `waitForOutboundDrain()` then for its frames.
    package func syncLagTimerPassForTesting() -> Bool {
        syncLagTimerPass(epoch: syncLagTimerEpoch)
    }

    private func runSyncLagTimerSync(epoch: UInt64) async {
        syncLagTimerSyncsInFlight[epoch, default: 0] += 1
        defer {
            if syncLagTimerSyncRequestedEpoch == epoch { syncLagTimerSyncRequestedEpoch = nil }
            endSyncLagTimerSync(epoch: epoch)
        }
        // A stale callback (the timer restarted since it was armed) takes no ticket, so it can't
        // bind a requester on a keeper never attached.
        guard epoch == syncLagTimerEpoch else { return }
        let ticket = await keeper.syncTurnTicket(via: self)
        await holds.at(.syncLagTimerSync)
        // The timer restarted meanwhile (a new epoch): this callback is stale.
        guard epoch == syncLagTimerEpoch else { return }
        guard let ticket else { return }
        _ = await keeper.syncTurnNow(via: self, reason: .lagTimer, ticket: ticket)
    }

    /// Lag timer callbacks running, by the epoch that armed them (an entry is removed at 0).
    private var syncLagTimerSyncsInFlight: [UInt64: Int] = [:]
    /// Test waiters, by id, for the callbacks of one epoch to return.
    private var syncLagTimerSyncWaitersForTesting: [Int: (epoch: UInt64, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextSyncLagTimerSyncWaiterForTesting = 0

    private func endSyncLagTimerSync(epoch: UInt64) {
        let left = (syncLagTimerSyncsInFlight[epoch] ?? 1) - 1
        syncLagTimerSyncsInFlight[epoch] = left > 0 ? left : nil
        guard left <= 0, !syncLagTimerSyncWaitersForTesting.isEmpty else { return }
        for (id, waiter) in syncLagTimerSyncWaitersForTesting where waiter.epoch == epoch {
            syncLagTimerSyncWaitersForTesting.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    /// Tests: the lag timer's current epoch (a callback armed now carries it).
    package var syncLagTimerEpochForTesting: UInt64 { syncLagTimerEpoch }

    /// Tests: returns once no lag timer callback of `epoch` is running (at once if none is), or
    /// when its task is cancelled (a test bounds it with `withinHangBound`).
    package func waitForSyncLagTimerSyncsForTesting(epoch: UInt64) async {
        guard syncLagTimerSyncsInFlight[epoch] != nil else { return }
        let id = nextSyncLagTimerSyncWaiterForTesting
        nextSyncLagTimerSyncWaiterForTesting += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || syncLagTimerSyncsInFlight[epoch] == nil {
                    continuation.resume()
                    return
                }
                syncLagTimerSyncWaitersForTesting[id] = (epoch, continuation)
            }
        } onCancel: {
            Task { await self.cancelSyncLagTimerSyncWaiterForTesting(id) }
        }
    }

    private func cancelSyncLagTimerSyncWaiterForTesting(_ id: Int) {
        syncLagTimerSyncWaitersForTesting.removeValue(forKey: id)?.continuation.resume()
    }

    /// Sessions with lag state (tests).
    package var syncLagTrackedSessionCount: Int { syncLag.count }

    /// The newest sequence in a session's FIFO, nil when it is empty or untracked (tests).
    package func syncLagLastCommittedSeqForTesting(_ sessionID: SessionID) -> UInt64? {
        syncLag[sessionID]?.unacked.last?.seq
    }

    /// The entries in a session's FIFO, nil when it is untracked (tests).
    package func syncLagUnackedCountForTesting(_ sessionID: SessionID) -> Int? {
        syncLag[sessionID]?.unackedCount
    }

    /// The commit's lag step: the frames it commits enter their sessions' FIFOs, its resyncs
    /// restart them, its pending marks and closes are applied. In the commit's segment.
    private func applySyncLag(_ plan: SyncPhasePlan) {
        guard let seq = plan.syncSeq else { return }
        let now = syncLagNow()
        let planned = plan.syncLag
        var received = Set<SessionID>()
        for frame in plan.frames where frame.isStateUpdate {
            received.insert(frame.sessionID)
        }
        for sessionID in received where planned.resyncs[sessionID] == nil {
            if syncLagPolicy.decisionsOff {
                syncLag[sessionID]?.committedKeepingNewest(seq, at: now)
            } else {
                syncLag[sessionID]?.committed(seq, at: now)
            }
        }
        // A joined session with no lag state whose full view this plan committed (its own
        // firstSync was dropped behind a commit, #564, and the cycle served it as an unsynced
        // recipient): tracking
        // starts here, as at a firstSync commit.
        for sessionID in received where syncLag[sessionID] == nil && sessionID != planned.firstSyncSession {
            guard !endedSessions.contains(sessionID), joiningSessions[sessionID] == nil,
                  let playerID = membershipCoordinator.playerID(for: sessionID),
                  plan.staged.firstSyncReceived.contains(playerID) else { continue }
            startSyncLagTracking(sessionID, plan: plan)
        }
        var resynced = false
        var profiled = TransportProfilerCounters.SyncLagWindow(droppedEvents: planned.droppedEvents)
        for (sessionID, counted) in planned.resyncs where received.contains(sessionID) {
            guard let playerID = membershipCoordinator.playerID(for: sessionID),
                  plan.staged.firstSyncReceived.contains(playerID) else {
                // It still got a state frame (its share of a broadcast frame): one more entry.
                syncLag[sessionID]?.committed(seq, at: now)
                continue
            }
            if counted {
                syncLag[sessionID]?.resynced(snapshotSeq: seq, at: now, policy: syncLagPolicy)
                syncLagResyncs += 1
                profiled.resyncs += 1
                resynced = true
            } else {
                syncLag[sessionID]?.resyncedAlongside(snapshotSeq: seq, at: now)
                syncLagResyncsAlongside += 1
                profiled.resyncsAlongside += 1
            }
        }
        syncLagDroppedEvents += planned.droppedEvents
        if resynced && planned.causedKeyScopeReset {
            syncLagKeyScopeResets += 1
            syncLagKeyScopeResetBytes += planned.keyScopeResetBytes
            profiled.keyScopeResets = 1
            profiled.keyScopeResetBytes = planned.keyScopeResetBytes
        }
        if let sessionID = planned.firstSyncSession, received.contains(sessionID) {
            startSyncLagTracking(sessionID, plan: plan)
        }
        for sessionID in planned.markPending {
            syncLag[sessionID]?.apply(.markPending, at: now)
            syncLagPendingMarks += 1
            profiled.pendingMarks += 1
        }
        if profiled != TransportProfilerCounters.SyncLagWindow() {
            syncLagProfilerCounters?.addSyncLag(profiled)
        }
        for close in planned.closes {
            closeLaggingSession(close.sessionID, code: close.code)
        }
    }

    /// A terminal lag close (4010, 4011), decided in a synchronous segment: the session stops
    /// getting frames and acks at once, and the close carries the connection generation captured
    /// here, so a later connection under the same session is never closed by it. The leave
    /// happens in the transport's close, before the close frame.
    private func closeLaggingSession(_ sessionID: SessionID, code: UInt16) {
        guard let phase = syncLag[sessionID]?.phase, phase != .closing else { return }
        syncLag[sessionID]?.apply(.close(code), at: syncLagNow())
        let reason: String
        switch code {
        case SessionClose.Code.slowConsumer:
            syncLagSlowConsumerCloses += 1
            syncLagProfilerCounters?.addSyncLag(.init(slowConsumerCloses: 1))
            reason = "slow consumer"
        default:
            syncLagUnresponsiveCloses += 1
            syncLagProfilerCounters?.addSyncLag(.init(unresponsiveCloses: 1))
            reason = "unresponsive"
        }
        logger.warning("Closing a lagging session", metadata: [
            "landID": .string(landID),
            "sessionID": .string(sessionID.rawValue),
            "code": .stringConvertible(code),
            "reason": .string(reason),
        ])
        endAndCloseSession(sessionID, code: code, reason: reason)
    }

    /// The common end of a terminal close decided in a synchronous segment: the session stops
    /// getting frames and acks at once, and the close carries the connection generation captured
    /// here, so a later connection under the same session is never closed by it.
    ///
    /// Every terminal close ends here (a lag close), so the
    /// decision line is written here, once per decision: each caller counts the close, and the
    /// counters and the lines agree.
    /// A failed land (#535): every session this adapter holds, joined or not, is ended in this
    /// segment (no frame to it, nothing from it reaches the keeper) and closed with 4016
    /// (`SessionClose.landFailed`). Returns once every close returned.
    ///
    /// This is the close without a host's stop path: the router's bindings end through each
    /// session's disconnect, and the manager drops the land by its epoch when the keeper's
    /// destroy calls `onLandDestroyed`.
    func closeSessionsForLandFailure(_ failure: LandFailure) async {
        let sessions = membershipCoordinator.connectedSessions
            .union(membershipCoordinator.joinedSessions)
            .sorted { $0.rawValue < $1.rawValue }
        var closes: [(SessionID, UInt64?)] = []
        for sessionID in sessions {
            closes.append((sessionID, connectionGenerations[sessionID]))
            endedSessions.insert(sessionID)
            inboundClosedSessions.insert(sessionID)
            if let drain = inboundAfterFlip.removeValue(forKey: sessionID) {
                inboundDroppedForJoiningSessions += drain.frames.count
            }
        }
        logger.error("Land failed; closing its sessions with 4016", metadata: [
            "landID": .string(landID),
            "sessions": .stringConvertible(closes.count),
            "failure": .string(failure.description),
        ])
        let transport = self.transport
        await withTaskGroup(of: Void.self) { group in
            for (sessionID, generation) in closes {
                group.addTask {
                    await transport.closeSession(sessionID, with: .landFailed, generation: generation)
                }
            }
        }
    }

    private func endAndCloseSession(_ sessionID: SessionID, code: UInt16, reason: String) {
        // The decision, per session: the caller's counters count it; the session's
        // `sessionClosed` line says whether this close or another cause ended the connection.
        lifecycleLog?.logSyncLagCloseDecided(sessionID: sessionID, code: code)
        let generation = connectionGenerations[sessionID]
        // Both directions end with the decision: no more frames to it, and nothing it sends
        // after reaches the keeper (its acks are ignored once closing).
        endedSessions.insert(sessionID)
        inboundClosedSessions.insert(sessionID)
        // A drain of its deferred inbound in progress stops too: what it still holds is dropped.
        if let drain = inboundAfterFlip.removeValue(forKey: sessionID) {
            inboundDroppedForJoiningSessions += drain.frames.count
        }
        let transport = self.transport
        let close = SessionClose(code: code, reason: reason, closeGrace: syncLagPolicy.closeGrace)
        let holds = self.holds
        Task {
            await holds.at(.syncLagClose, isolation: nil)
            await transport.closeSession(sessionID, with: close, generation: generation)
            await holds.at(.syncLagClosed, isolation: nil)
        }
    }

    // MARK: - Sync phase: plan + commit

    /// Plans and commits one sync phase in the same actor turn. A plan that throws commits
    /// nothing and requests a key scope reset (`keyScopeResetPending`).
    ///
    /// With profiling on, the plan's duration (extraction, diffs and encoding) is sampled as the
    /// encode latency; the clock is read here, never inside a plan.
    ///
    /// `isSyncCycle` tags the committed writer element for the back-pressure rule
    /// (`hasPendingStateElement`); a joiner's firstSync passes `false`.
    private func runSyncPhase(
        isSyncCycle: Bool = true,
        read: SyncOutputRead? = nil,
        _ plan: () throws -> SyncPhasePlan
    ) throws {
        syncOutputRead = read
        // The plan's sequence and resync players are mirrored for the encodes only while the
        // plan is built: plan functions are synchronous, and the plan value holds the decision.
        defer {
            syncOutputRead = nil
            planSyncSeq = nil
            planResyncPlayers = []
        }
        let planStart: ContinuousClock.Instant? = profiler != nil ? ContinuousClock.now : nil
        let planned: SyncPhasePlan
        do {
            planned = try plan()
        } catch {
            keyScopeResetPending = true
            syncFailedPlans += 1
            profilerCounters?.incrementSyncFailedPlans()
            logSyncFailureIfDue(error)
            throw error
        }
        commitSyncPhase(planned, isSyncCycle: isSyncCycle)
        if let times = planned.phaseTimes {
            profilerCounters?.addSyncPhaseTimes(extract: times.extract, broadcast: times.broadcast, perPlayer: times.perPlayer, combined: times.combined)
            lastSyncPhaseTimesForTesting = times
        }
        if let planStart {
            recordEncodeSample(ContinuousClock.now - planStart)
        }
    }

    /// Logs a failed sync plan, at most every 10 seconds. The failure ends the land (#535), so
    /// normally only one plan fails; the bound covers the plans already in flight.
    private func logSyncFailureIfDue(_ error: any Error) {
        let now = ContinuousClock.now
        if let last = lastSyncFailureLog, now - last < .seconds(10) {
            return
        }
        lastSyncFailureLog = now
        logger.error("❌ Sync plan failed; nothing was committed, and the land ends", metadata: [
            "landID": .string(landID),
            "failedPlans": .string("\(syncFailedPlans)"),
            "error": .string("\(error)")
        ])
    }

    /// One full sync cycle on `state`: plan, then commit. If the plan throws, the dirty fields
    /// cleared when this phase's copy was taken are carried into the next plan.
    private func runFullSyncPhase(state: State, read: SyncOutputRead? = nil, joiners: [SyncPhaseJoiner] = []) throws {
        do {
            try runSyncPhase(read: read) {
                try planSyncPhase(
                    state: state,
                    recipients: syncPhaseRecipients(),
                    joiners: joiners,
                    events: pendingEventManager,
                    fullSnapshot: syncStrategy == .fullSnapshot,
                    resetsKeyScopes: keyScopeResetPending
                )
            }
        } catch {
            // The copy was taken before the flags were cleared, so it still has them.
            carriedDirtyFields.formUnion(state.getDirtyFields())
            throw error
        }
    }

    // MARK: - Sync stream (record format 2.1)

    /// The sync-stream drafts the running in-turn phase made, returned with its output (#553).
    private var inTurnSyncStreamDrafts: [SyncStreamDraft] = []

    /// Whether the keeper records its sync stream. This adapter runs on the keeper's executor.
    private func keeperRecordsSyncStream() -> Bool {
        keeper.assumeIsolated { $0.recordsSyncStream }
    }

    /// A plan with a digest when its sync output is recorded.
    private func makePlan() -> SyncPhasePlan {
        var plan = SyncPhasePlan()
        if syncOutputRead != nil {
            plan.digest = SyncOutputDigestInput()
            syncOutputDigestCountForTesting += 1
        }
        if tracksSyncLag {
            lastSyncSeq += 1
            plan.syncSeq = lastSyncSeq
        }
        planSyncSeq = plan.syncSeq
        planResyncPlayers = []
        return plan
    }

    /// Records a committed plan's output (or a firstSync's seed) in the keeper's sync stream.
    /// Runs in the commit's synchronous segment, so commit order is stream order. An in-turn
    /// phase's entries go back to the keeper as drafts with the phase's output (#553), the freeze
    /// settle's included (#546 L2d-1); a standalone initial sync's, outside a turn (recorded as
    /// `.legacyCycle`), are submitted now.
    private func recordSyncStream(_ digest: SyncOutputDigestInput, broadcastCommitted: Bool, read: SyncOutputRead) {
        var drafts: [SyncStreamDraft] = []
        defer {
            if read.turnKind == .legacyCycle {
                keeper.assumeIsolated { $0.submitSyncStream(drafts) }
            } else {
                inTurnSyncStreamDrafts.append(contentsOf: drafts)
            }
        }
        let observedTickId = read.position?.observedTickId
        let sequence = read.position?.sequence ?? -1
        let afterPass = read.position?.afterPass
        // A resynced player's view restarts: a clear before this plan's output, for the players
        // whose snapshot committed (a seed follows). One whose snapshot didn't encode keeps its
        // view, live and in the stream.
        for playerID in digest.resyncPlayers.filter({ digest.seeds[$0] != nil }).sorted(by: { SnapshotValue.utf8Less($0.rawValue, $1.rawValue) }) {
            syncStreamUnverifiedPlayers.remove(playerID)
            syncStreamViewPlayers.remove(playerID)
            drafts.append(SyncStreamCanonical.clearDraft(playerID))
        }
        if !digest.isFirstSync {
            let broadcastHash = broadcastCommitted
                ? digest.broadcastPatches.map { SyncStreamCanonical.scopeHash($0, scope: SyncOutputDigestInput.broadcastScope) }
                : nil
            var perPlayerHash: UInt64?
            var perPlayerUnverified: [String]?
            var perPlayerUncommitted: [String]?
            var perPlayerHashes: [String: UInt64]?
            var patches: [String: [StatePatch]]?
            if syncStreamDetail.contains(.patches), broadcastCommitted, let broadcast = digest.broadcastPatches {
                patches = [SyncOutputDigestInput.broadcastScope: CanonicalPatchList(broadcast).patches.map(\.jsonSafe)]
            }
            if digest.commitsPerPlayer {
                // Players with patches only: an empty update (a key scope reset sends one) is
                // the same as no update for the verifier.
                let hashed = digest.perPlayerPatches
                    .filter { digest.seeds[$0.key] == nil && !$0.value.isEmpty && !syncStreamUnverifiedPlayers.contains($0.key) }
                let pairs = hashed.map { ($0.key.rawValue, SyncStreamCanonical.scopeHash($0.value, scope: $0.key.rawValue)) }
                perPlayerHash = CanonicalPatchList.combinedHash(pairs)
                if syncStreamDetail.contains(.perPlayerHashes) {
                    perPlayerHashes = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
                }
                if syncStreamDetail.contains(.patches) {
                    var scopes = patches ?? [:]
                    for (playerID, playerPatches) in hashed {
                        scopes[playerID.rawValue] = CanonicalPatchList(playerPatches).patches.map(\.jsonSafe)
                    }
                    patches = scopes
                }
                // Replay checks what this output produced: a player with a view it doesn't address
                // is listed as unverified, as one whose view isn't verifiable is. It isn't
                // addressed when its sessions ended before its clear (the leave's own turn), or
                // when sync lag left out every one of them (#572; the pause ends in a resync's
                // clear and seed, or in the leave's clear).
                let recipients = Set(digest.recipients)
                let departed = syncStreamViewPlayers.filter {
                    !recipients.contains($0) && digest.seeds[$0] == nil && membershipCoordinator.sessionIDs(for: $0).isEmpty
                }
                let withheld = digest.withheldPlayers.filter { syncStreamViewPlayers.contains($0) && digest.seeds[$0] == nil }
                let unverified = digest.recipients.filter { syncStreamUnverifiedPlayers.contains($0) }
                    + Array(departed.union(withheld))
                perPlayerUnverified = unverified.isEmpty ? nil : SyncStreamCanonical.sortedIDs(unverified)
                perPlayerUncommitted = digest.uncommitted.isEmpty ? nil : SyncStreamCanonical.sortedIDs(Array(digest.uncommitted))
            }
            let eventsHash = digest.events.map(CanonicalSyncEvent.hash)
            let eventsThroughSequence = digest.eventsThroughSequence
            let eventsNotQueued = syncStreamUnqueuedEvents.isEmpty ? nil : syncStreamUnqueuedEvents.sorted()
            syncStreamUnqueuedEvents.removeAll()
            let eventsNotMerged = syncStreamUnmergedEvents.isEmpty ? nil : syncStreamUnmergedEvents.sorted()
            syncStreamUnmergedEvents = ReevaluationUnmergedEvents()
            let extractionDrops = digest.extractionDrops
            let encodeDropScopes = digest.encodeDropScopes.sorted { SnapshotValue.utf8Less($0, $1) }
            let turnKind = read.turnKind
            let resetsKeyScopes = digest.resetsKeyScopes
            drafts.append(SyncStreamDraft(.output(observedTickId: observedTickId) { [perPlayerHash, perPlayerUnverified, perPlayerUncommitted, perPlayerHashes, patches] streamIndex, index in
                ReevaluationRecordedSyncOutput(
                    index: index,
                    turnKind: turnKind,
                    observedTickId: observedTickId,
                    streamIndex: streamIndex,
                    sequence: sequence,
                    afterPass: afterPass,
                    broadcastHash: broadcastHash,
                    perPlayerHash: perPlayerHash,
                    perPlayerUnverified: perPlayerUnverified,
                    perPlayerUncommitted: perPlayerUncommitted,
                    perPlayerHashes: perPlayerHashes,
                    eventsHash: eventsHash,
                    eventsThroughSequence: eventsThroughSequence,
                    eventsNotQueued: eventsNotQueued,
                    eventsNotMerged: eventsNotMerged,
                    resetsKeyScopes: resetsKeyScopes ? true : nil,
                    extractionDrops: extractionDrops,
                    encodeDropScopes: encodeDropScopes,
                    patches: patches
                )
            }))
        }
        for (playerID, seed) in digest.seeds.sorted(by: { SnapshotValue.utf8Less($0.key.rawValue, $1.key.rawValue) }) {
            let rejoin = !syncStreamSeededPlayers.insert(playerID).inserted
            syncStreamViewPlayers.insert(playerID)
            let viewDrops = seed.drops.sorted { $0.rawValue < $1.rawValue }
            if viewDrops.isEmpty {
                syncStreamUnverifiedPlayers.remove(playerID)
            } else {
                syncStreamUnverifiedPlayers.insert(playerID)
            }
            let viewHash = viewDrops.isEmpty ? SyncStreamCanonical.scopeHash(seed.patches, scope: playerID.rawValue) : nil
            let dropFields = Array(Set(seed.dropFields)).sorted { SnapshotValue.utf8Less($0, $1) }
            drafts.append(SyncStreamDraft(.marker { streamIndex, _ in
                ReevaluationRecordedSyncMarker(
                    kind: .seed,
                    playerID: playerID.rawValue,
                    observedTickId: observedTickId,
                    streamIndex: streamIndex,
                    sequence: sequence,
                    afterPass: afterPass,
                    rejoin: rejoin,
                    viewHash: viewHash,
                    viewDrops: viewDrops,
                    viewDropFields: dropFields.isEmpty ? nil : dropFields
                )
            }))
        }
    }

    /// Records a clear marker: the player's per-player cache and firstSync mark were dropped.
    /// `outsideTurn`: recorded after the leave's turn, outside any keeper turn (a disconnect);
    /// a tickless land then closes it as its own turn record (#327). A superseded session's
    /// clear is recorded in the join's admission, and the join's input turn closes it.
    private func recordSyncStreamClear(_ playerID: PlayerID, outsideTurn: Bool = false) {
        guard keeperRecordsSyncStream() else { return }
        syncStreamUnverifiedPlayers.remove(playerID)
        syncStreamViewPlayers.remove(playerID)
        let draft = SyncStreamCanonical.clearDraft(playerID)
        keeper.assumeIsolated { $0.submitSyncStream([draft], outsideTurn: outsideTurn) }
    }

    /// The dirty fields a plan diffs: the state's, plus those carried from failed plans.
    private func planDirtyFields(of state: State) -> Set<String> {
        carriedDirtyFields.isEmpty ? state.getDirtyFields() : state.getDirtyFields().union(carriedDirtyFields)
    }

    /// Whether a plan has dirty fields to diff (`planDirtyFields(of:)` is not empty).
    private func planIsDirty(_ state: State) -> Bool {
        state.isDirty() || !carriedDirtyFields.isEmpty
    }

    /// Logs dropped updates (data loss), at most every 10 seconds.
    /// Counts targeted events a joining session doesn't get (`eventsDroppedForJoiningSessions`).
    func noteEventsDroppedForJoiningSessions(_ count: Int) {
        guard count > 0 else { return }
        eventsDroppedForJoiningSessions += count
        let now = ContinuousClock.now
        if let last = lastJoiningEventDropLog, now - last < .seconds(10) { return }
        lastJoiningEventDropLog = now
        if logger.logLevel <= .debug {
            logger.debug("Targeted events to a joining session were not delivered", metadata: [
                "dropped": .stringConvertible(count),
                "droppedTotal": .stringConvertible(eventsDroppedForJoiningSessions),
            ])
        }
    }

    /// Of the first `end` queued targeted events, those addressed to a session that is still
    /// joining and doesn't hold events (sessions × events): a plan consumes them without
    /// delivering them to it. A session that holds events gets them at its flip instead.
    private func targetedEventsForJoiningSessions(endingBefore end: Int) -> Int {
        guard end > 0 else { return 0 }
        return joiningSessions.reduce(0) { sum, entry in
            guard !holdsEvents(entry.key) else { return sum }
            return sum + pendingTargetedEventBodies(
                events: pendingEventManager,
                for: entry.key,
                playerID: entry.value.playerID,
                endingBefore: end
            ).count
        }
    }

    // MARK: - Held events (#69)

    /// The bound on the targeted events held for one joining session.
    private var heldEventsLimit: (count: Int, bytes: Int) {
        heldEventsLimitForTesting ?? (JoinFlipConfig.heldEventsMax, JoinFlipConfig.heldEventsMaxBytes)
    }

    /// Tests only: replaces the held-event bound (`JoinFlipConfig.heldEventsMax` /
    /// `heldEventsMaxBytes`); nil restores it.
    func setHeldEventsLimitForTesting(count: Int, bytes: Int) {
        heldEventsLimitForTesting = (count, bytes)
    }

    /// Whether targeted events to `sessionID` are held for it: an in-turn join that hasn't failed.
    func holdsEvents(_ sessionID: SessionID) -> Bool {
        guard let inTurn = joiningSessions[sessionID]?.inTurn else { return false }
        return !inTurn.failed
    }

    /// Whether holding `frames` too would take `sessionID`'s held events over the bound.
    private func heldEventsWouldOverflow(_ sessionID: SessionID, adding frames: [EncodedFrame]) -> Bool {
        guard let joining = joiningSessions[sessionID], !frames.isEmpty else { return false }
        let limit = heldEventsLimit
        let bytes = frames.reduce(0) { $0 + $1.data.count }
        return joining.heldEvents.count + frames.count > limit.count || joining.heldBytes + bytes > limit.bytes
    }

    /// Holds `frames` (encoded event frames) for the joining `sessionID`, after the ones it
    /// holds. Returns false when that goes over the bound: then the session's held events and
    /// `frames` are discarded and counted, and the caller fails the join with `eventOverflow`.
    private func holdEvents(_ frames: [EncodedFrame], for sessionID: SessionID) -> Bool {
        guard !frames.isEmpty, var joining = joiningSessions[sessionID] else { return true }
        if heldEventsWouldOverflow(sessionID, adding: frames) {
            noteEventsDroppedForJoiningSessions(joining.heldEvents.count + frames.count)
            joining.heldEvents = []
            joining.heldBytes = 0
            joiningSessions[sessionID] = joining
            return false
        }
        joining.heldEvents.append(contentsOf: frames)
        joining.heldBytes += frames.reduce(0) { $0 + $1.data.count }
        joiningSessions[sessionID] = joining
        return true
    }

    /// A target resolution's event for a joining session: held when the session holds events
    /// (an overflow is recorded, and fails the join after the emit returns), counted as
    /// dropped otherwise.
    func holdOrDropEvent(_ frame: EncodedFrame?, for sessionID: SessionID) {
        guard let frame, holdsEvents(sessionID) else {
            noteEventsDroppedForJoiningSessions(1)
            return
        }
        if !holdEvents([frame], for: sessionID) {
            heldEventOverflows.append(sessionID)
        }
    }

    /// Drops the inbound frames deferred for `sessionID`'s join (it ends without a flip),
    /// counted. The record keeps refusing frames while it stays (`deferInbound`).
    private func discardDeferredInbound(of sessionID: SessionID) {
        guard let joining = joiningSessions[sessionID], !joining.deferredInbound.isEmpty else { return }
        inboundDroppedForJoiningSessions += joining.deferredInbound.count
        joiningSessions[sessionID]?.deferredInbound = []
        joiningSessions[sessionID]?.deferredInboundBytes = 0
    }

    /// Fails the in-turn joins whose held events went over the bound in a target resolution.
    private func failHeldEventOverflows() {
        let sessions = heldEventOverflows
        heldEventOverflows.removeAll()
        for sessionID in sessions {
            failInTurnJoin(sessionID: sessionID, reason: .eventOverflow)
        }
    }

    /// Discards the events held for `sessionID` (its join ends without a flip), counted as
    /// dropped. With `includingQueued` (the record goes now) the opcode 107 targeted events
    /// still queued for it are counted too: no later plan finds the session to count them.
    /// Call it before the session's membership changes, while their stamps still match.
    private func discardHeldEvents(of sessionID: SessionID, includingQueued: Bool = false) {
        guard let joining = joiningSessions[sessionID] else { return }
        var count = joining.heldEvents.count
        if includingQueued && useStateUpdateWithEvents && joining.inTurn != nil {
            count += pendingTargetedEventBodies(
                events: pendingEventManager,
                for: sessionID,
                playerID: joining.playerID,
                endingBefore: pendingEventManager.targetedEventCount
            ).count
        }
        guard count > 0 else { return }
        joiningSessions[sessionID]?.heldEvents = []
        joiningSessions[sessionID]?.heldBytes = 0
        noteEventsDroppedForJoiningSessions(count)
    }

    /// Opcode 107: the event frames of the first `end` queued targeted events for each session
    /// that holds events, with the stamp checks a joined recipient's events get. In-turn
    /// joiners past the flip budget are included: they keep their events to their own flip.
    private func heldEventFrames(events: PendingEventManager, endingBefore end: Int) throws -> [SessionID: [EncodedFrame]] {
        guard end > 0 else { return [:] }
        var held: [SessionID: [EncodedFrame]] = [:]
        for (sessionID, joining) in joiningSessions where holdsEvents(sessionID) {
            let bodies = pendingTargetedEventBodies(
                events: events,
                for: sessionID,
                playerID: joining.playerID,
                endingBefore: end
            )
            var frames: [SyncPhaseFrame] = []
            try appendEventFrames(bodies, to: sessionID, into: &frames)
            if !frames.isEmpty {
                held[sessionID] = frames.map { EncodedFrame(data: $0.data, kind: $0.kind) }
            }
        }
        return held
    }

    /// This cycle's recipients, in membership order.
    private func syncPhaseRecipients() -> [SyncPhaseRecipient] {
        var recipients: [SyncPhaseRecipient] = []
        recipients.reserveCapacity(membershipCoordinator.joinedCount())
        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers[playerID] != nil || joiningSessions[sessionID] != nil {
                continue
            }
            recipients.append(SyncPhaseRecipient(sessionID: sessionID, playerID: playerID))
        }
        // One session per player (#531): both join paths supersede, so no player is a recipient
        // twice. The per-player sync state (baseline, caches) is the player's, not the session's
        // (#539). The multi-session branches elsewhere stay as defensive code.
        assert(
            Set(recipients.map(\.playerID)).count == recipients.count,
            "a player has two sync recipients: \(recipients.map { "\($0.playerID.rawValue)/\($0.sessionID.rawValue)" })"
        )
        return recipients
    }

    /// The commit of a sync phase: synchronous, in the same actor turn as its plan.
    ///
    /// Writes the staged caches and firstSync marks, removes the events the plan consumed, and
    /// enqueues the frames as one writer element. Dirty
    /// flags were cleared by the keeper when it took the phase's copy (#68); a committed full plan
    /// ends the carry of failed plans' dirty fields, and one that reset the key scopes ends a
    /// pending reset.
    private func commitSyncPhase(_ plan: SyncPhasePlan, isSyncCycle: Bool) {
        syncPhaseCommits &+= 1
        #if DEBUG
        if let sessionID = plan.syncLag.firstSyncSession {
            noteJoinCommitForTesting(sessionID, flipped: false)
        }
        // The full views of unsynced recipients (#564) whose state frame this plan commits.
        for sessionID in plan.initialViewSessions
        where plan.frames.contains(where: { $0.sessionID == sessionID && $0.isStateUpdate }) {
            noteJoinCommitForTesting(sessionID, flipped: false)
        }
        #endif
        if var digest = plan.digest, let read = syncOutputRead {
            if useStateUpdateWithEvents {
                let consumed = pendingEventManager.consumedEventDigests(
                    targeted: plan.consumedEvents.targeted,
                    broadcast: plan.consumedEvents.broadcast
                )
                digest.eventsThroughSequence = consumed.events.map(\.sequence).max()
                if consumed.complete {
                    digest.events = consumed.events
                } else {
                    // Unverifiable, never a hash over a partial set.
                    digest.encodeDropScopes.insert(SyncOutputDigestInput.eventsScope)
                }
            }
            syncOutputDigestFaultForTesting?(&digest)
            recordSyncStream(
                digest,
                broadcastCommitted: plan.staged.broadcast != nil || plan.stagedTables.holdsBroadcastDiff,
                read: read
            )
        }
        syncEngine.applyStaged(plan.staged)
        broadcastTables?.apply(plan.stagedTables)
        perPlayerTables?.apply(plan.stagedPerPlayerTables)
        // Before the flips end their joining: what this plan consumes for joining sessions is
        // held for those that hold events (#69), and not delivered to the others.
        let held = plan.heldEvents.flatMap { plan.heldEventsEnd == plan.consumedEvents.targeted ? $0 : nil }
            ?? plan.heldEventFramesPacked()
        var overflowed: [SessionID] = []
        for (sessionID, frames) in held where !holdEvents(frames, for: sessionID) {
            overflowed.append(sessionID)
        }
        noteEventsDroppedForJoiningSessions(targetedEventsForJoiningSessions(endingBefore: plan.consumedEvents.targeted))
        // The flips (#69), in the commit's segment: the joins end, their waiters resume. Each
        // flip's held events follow its firstSync in this element.
        var frames = plan.frames.map { sessionFrame($0.data, kind: $0.kind, to: $0.sessionID) }
        var drainsToStart: [SessionID] = []
        for flip in plan.flips where joiningSessions[flip.sessionID]?.ticket == flip.ticket {
            guard let joining = joiningSessions.removeValue(forKey: flip.sessionID) else { continue }
            noteSessionJoined(flip.sessionID, playerID: joining.playerID)
            startSyncLagTracking(flip.sessionID, plan: plan)
            for held in joining.heldEvents {
                frames.append(sessionFrame(held, to: flip.sessionID))
            }
            // The frames the session sent while joining are applied after its flip, in order,
            // by a drain started once this element is enqueued (#69).
            if !joining.deferredInbound.isEmpty {
                inboundAfterFlip[flip.sessionID] = InboundDrain(
                    ticket: joining.ticket,
                    frames: joining.deferredInbound,
                    bytes: joining.deferredInboundBytes
                )
                drainsToStart.append(flip.sessionID)
            }
            eventsHeldForJoiningSessions += joining.heldEvents.count
            inTurnJoinFlips += 1
            #if DEBUG
            noteJoinCommitForTesting(flip.sessionID, flipped: true)
            #endif
            // Before the JoinResponse is enqueued below: once the client holds it, the router
            // must already answer a second join as joined (#867).
            joining.inTurn?.attemptEnd?.markFlipped()
            joinWaiters[flip.sessionID]?.resolve(.success(()))
        }
        pendingEventManager.removeConsumed(
            targeted: plan.consumedEvents.targeted,
            broadcast: plan.consumedEvents.broadcast
        )
        if plan.isFullCycle {
            carriedDirtyFields.removeAll()
        }
        if plan.resetsKeyScopes {
            keyScopeResetPending = false
        }
        if plan.resetsKeyScopes {
            broadcastKeysMayBeDefined = false
        }
        if plan.encodesBroadcastPatches {
            broadcastKeysMayBeDefined = true
        }
        if plan.needsBroadcastKeyReset && broadcastKeysMayBeDefined {
            keyScopeResetPending = true
        }
        if plan.stateUpdateCount > 0 {
            profilerCounters?.incrementStateUpdates(by: plan.stateUpdateCount)
        }
        if isSyncCycle {
            profilerCounters?.incrementSyncCycles()
        }
        applySyncLag(plan)
        // A failed land sends no new state or event frame (#535 output gate), and starts no
        // inbound drain; the join failures below still run.
        if !outputGate.isClosed {
            enqueueFrames(frames, isSyncCycle: isSyncCycle)
            // After the whole flip element (JoinResponse, firstSync, held events) is enqueued: the
            // flipped sessions' deferred frames, each from a Task of its own, never inline here.
            for sessionID in drainsToStart {
                let drain = Task { await self.drainInbound(sessionID) }
                #if DEBUG
                inboundDrainTasksForTesting[sessionID] = drain
                #endif
            }
        }
        // After the commit: the joins this plan's events took over the held-event bound. A full
        // plan left them out of its flips.
        for sessionID in overflowed {
            failInTurnJoin(sessionID: sessionID, reason: .eventOverflow)
        }
    }

    /// Plan of one full sync cycle (`syncNow`).
    ///
    /// Synchronous: nothing else runs on this adapter between reading its inputs and the commit.
    /// Reads `state` (the phase's copy), `recipients` and `events`; stages the cache
    /// updates in the plan; encodes every frame. `fullSnapshot` (the full-snapshot strategy)
    /// extracts `.all` and diffs against the `.empty` baseline. `resetsKeyScopes` types every
    /// recipient's updates `.firstSync`, sent even when empty (see `keyScopeResetPending`).
    /// An update that fails to encode, or a field whose snapshot conversion throws
    /// (`SyncEngine.ExtractionDrops`), makes the plan throw a `LandFailure`: the land ends (#535).
    ///
    /// Frames per session, in order (the outbound writer keeps it, #60):
    /// - opcode 107: the merged broadcast frame (broadcast state update + broadcast events), then
    ///   the session's targeted event frames, then its per-player state frame;
    /// - json / opcodeJsonArray: one combined state frame. Events are not queued in these
    ///   encodings; each was sent when emitted, so it precedes every state frame sent after it.
    /// Events queued after this plan read the queue are delivered by the next cycle.
    private func planSyncPhase(
        state: State,
        recipients: [SyncPhaseRecipient],
        joiners: [SyncPhaseJoiner] = [],
        events: PendingEventManager,
        fullSnapshot: Bool,
        resetsKeyScopes: Bool
    ) throws -> SyncPhasePlan {
        var plan = makePlan()
        plan.isFullCycle = true
        let requestedKeyScopeReset = resetsKeyScopes
        let recipients = classifySyncLag(recipients, events: events, into: &plan)
        // Opcode 107: what this plan's targeted events hold for each joining session (#69). A
        // joiner they would take over the held-event bound is not flipped by this plan: the
        // commit fails it with `eventOverflow` instead, so it never flips a join it also fails.
        var joiners = joiners
        if useStateUpdateWithEvents {
            let held = try heldEventFrames(events: events, endingBefore: events.targetedEventCount)
            plan.heldEvents = held
            plan.heldEventsEnd = events.targetedEventCount
            joiners.removeAll { joiner in
                held[joiner.recipient.sessionID].map { heldEventsWouldOverflow(joiner.recipient.sessionID, adding: $0) } ?? false
            }
        }
        // A plan without a recipient resets no client's key tables: the reset stays pending.
        plan.resetsKeyScopes = resetsKeyScopes && !recipients.isEmpty
        let baseline: SyncEngine.DiffBaseline = fullSnapshot ? .empty : .cached
        let extractAll = fullSnapshot
        var drops = ExtractionDrops()
        let (requestedBroadcastMode, requestedPerPlayerMode) = computeSyncModes(for: state, extractAll: extractAll)
        // `extractSyncSnapshots` may extract with a different mode than requested
        // when `useSnapshotForSync` is enabled: it derives a single combined dirty-field mode from
        // `state.getDirtyFields()` rather than reusing `requestedBroadcastMode`/`requestedPerPlayerMode`
        // verbatim. Diffing must use the mode that was actually applied during extraction, or fields
        // excluded from extraction (because they weren't in that combined dirty set) get misread as
        // newly-added when compared against the broadcast cache.
        // Phase timing only with profiling on: no clock is read otherwise.
        let timed = profilerCounters != nil
        let extractStart: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil
        // On the tables the broadcast diff reads the state itself, and runs first: the
        // per-player extraction below needs to know whether a broadcast field threw.
        var tablesBroadcastDiff: [StatePatch]?
        if let broadcastTables {
            let fields = modesBesideTables(
                for: state, extractAll: extractAll, broadcastMode: requestedBroadcastMode, perPlayerMode: requestedPerPlayerMode
            ).broadcast.fields
            // The same fields today's extraction would take, so the seed and the diff match it.
            tablesBroadcastDiff = broadcastTables.planDiff(state, fields: fields, drops: &drops, into: &plan.stagedTables)
        }
        let (broadcastSnapshot, perPlayerByPlayer, broadcastMode, perPlayerMode) = extractSyncSnapshots(
            from: state,
            recipients: recipients,
            broadcastMode: requestedBroadcastMode,
            perPlayerMode: requestedPerPlayerMode,
            extractAll: extractAll,
            drops: &drops
        )
        // The per-player tables (#514) keep today's branch: the one-pass extraction when it is
        // on and no broadcast field dropped (it seeds every per-player field and has no entry for
        // a state without per-player fields), else the separate one (an entry per player).
        let perPlayerOnePass = useSnapshotForSync && drops.broadcastFields.isEmpty
        let extractEnd: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil

        var broadcastDiff: [StatePatch]
        if let tablesBroadcastDiff {
            broadcastDiff = tablesBroadcastDiff
        } else {
            broadcastDiff = SyncPlanning.withoutDroppedFields(
                syncEngine.computeBroadcastDiffFromSnapshot(
                    currentBroadcast: broadcastSnapshot,
                    onlyPaths: nil,
                    mode: broadcastMode,
                    baseline: baseline,
                    staged: &plan.staged
                ),
                dropped: drops.broadcastFields,
                baseline: baseline
            )
        }
        let broadcastEnd: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil
        var perPlayerTime: Duration = .zero

        // Recipients whose player has no committed firstSync (e.g. its firstSync plan failed):
        // their client view is empty. Read before any update below stages a mark.
        // A resynced player (#332) is planned like one: its whole view, typed a resync.
        let unsyncedRecipients = recipients.filter {
            plan.syncLag.resyncPlayers.contains($0.playerID) || !syncEngine.hasReceivedFirstSync($0.playerID, staged: plan.staged)
        }
        let skippedPlayers = Set(unsyncedRecipients.map(\.playerID))
        // An unsynced recipient's broadcast key map is empty (#90): with merged broadcast frames
        // this plan resets the key scopes, so its broadcast frame defines every key it uses.
        let resetsKeyScopes = resetsKeyScopes
            || (usesBroadcastKeyTable && broadcastKeysMayBeDefined && !unsyncedRecipients.isEmpty)
        plan.resetsKeyScopes = resetsKeyScopes && !recipients.isEmpty

        var pendingUpdates: [PendingSyncUpdate]
        if useStateUpdateWithEvents {
            let framesBefore = plan.frames.count
            try planMergedBroadcastFrame(
                broadcastDiff: broadcastDiff,
                recipients: recipients,
                events: events,
                resetsKeyScope: resetsKeyScopes,
                into: &plan
            )
            // The broadcast key-scope reset this plan's resyncs caused, and its bytes (#332).
            if resetsKeyScopes && !requestedKeyScopeReset && !plan.syncLag.resyncPlayers.isEmpty {
                plan.syncLag.causedKeyScopeReset = true
                plan.syncLag.keyScopeResetBytes = plan.frames[framesBefore...].filter(\.isStateUpdate).reduce(0) { $0 + $1.data.count }
            }
            let perPlayerStart: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil
            if let perPlayerTables {
                pendingUpdates = collectPerPlayerTablePendingUpdates(
                    perPlayerTables, state: state, recipients: recipients, broadcastDiff: nil,
                    perPlayerMode: perPlayerMode, onePass: perPlayerOnePass, baseline: baseline,
                    typesFirstSync: resetsKeyScopes, skipping: skippedPlayers, drops: &drops, plan: &plan
                )
            } else {
                pendingUpdates = collectPerPlayerOnlyPendingUpdates(
                    recipients: recipients,
                    perPlayerByPlayer: perPlayerByPlayer,
                    perPlayerMode: perPlayerMode,
                    baseline: baseline,
                    typesFirstSync: resetsKeyScopes,
                    skipping: skippedPlayers,
                    staged: &plan.staged
                )
            }
            if let perPlayerStart { perPlayerTime = ContinuousClock.now - perPlayerStart }
        } else {
            let perPlayerStart: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil
            if let perPlayerTables {
                pendingUpdates = collectPerPlayerTablePendingUpdates(
                    perPlayerTables, state: state, recipients: recipients, broadcastDiff: broadcastDiff,
                    perPlayerMode: perPlayerMode, onePass: perPlayerOnePass, baseline: baseline,
                    typesFirstSync: resetsKeyScopes, skipping: skippedPlayers, drops: &drops, plan: &plan
                )
            } else {
                pendingUpdates = collectCombinedPendingUpdates(
                    recipients: recipients,
                    broadcastDiff: broadcastDiff,
                    perPlayerByPlayer: perPlayerByPlayer,
                    perPlayerMode: perPlayerMode,
                    baseline: baseline,
                    typesFirstSync: resetsKeyScopes,
                    skipping: skippedPlayers,
                    staged: &plan.staged
                )
            }
            if let perPlayerStart { perPlayerTime = ContinuousClock.now - perPlayerStart }
        }
        pendingUpdates = withoutDroppedFields(pendingUpdates, drops: drops, baseline: baseline)
        if plan.digest != nil {
            plan.digest?.commitsPerPlayer = true
            plan.digest?.resetsKeyScopes = resetsKeyScopes
            plan.digest?.recipients = recipients.map(\.playerID).filter { !skippedPlayers.contains($0) }
            plan.digest?.broadcastPatches = broadcastTables?.liveDigestForm(of: broadcastDiff, staged: plan.stagedTables) ?? broadcastDiff
            for update in pendingUpdates where plan.digest?.perPlayerPatches[update.playerID] == nil {
                // A combined update carries the broadcast patches too: digested in the live form.
                let patches = update.update.patchList
                plan.digest?.perPlayerPatches[update.playerID] = broadcastTables?.liveDigestForm(of: patches, staged: plan.stagedTables) ?? patches
            }
        }
        // Row addressing (section 4 of the row addressing plan): with merged frames an unsynced
        // recipient also gets the shared frame, so its view holds the committed tables and goes
        // ahead of that frame; a combined frame's view holds this plan's tables.
        let viewsFromStagedTables = !useStateUpdateWithEvents
        for recipient in unsyncedRecipients {
            #if DEBUG
            if !plan.syncLag.resyncPlayers.contains(recipient.playerID) {
                plan.initialViewSessions.append(recipient.sessionID)
            }
            #endif
            let dropsBefore = drops.count
            let viewFieldsBefore = drops.viewFields.count
            let (update, viewPatches) = planFullViewUpdate(
                state: state, recipient: recipient, staged: &plan.staged, stagedTables: &plan.stagedTables,
                stagedPerPlayerTables: &plan.stagedPerPlayerTables, drops: &drops,
                rowsFromStagedTables: viewsFromStagedTables
            )
            pendingUpdates.append(update)
            if plan.digest != nil {
                var seed = SyncOutputDigestInput.SeedDigest(patches: viewPatches)
                if drops.count != dropsBefore { seed.drops.insert(.extraction) }
                seed.dropFields = Array(drops.viewFields[viewFieldsBefore...])
                plan.digest?.seeds[recipient.playerID] = seed
            }
        }
        // Flipping joiners (#69): their whole view from the turn's end state, a seed each, like
        // the unsynced recipients above. They are not recipients of the merged broadcast frame
        // or of targeted events: that state is in their firstSync.
        var joinerUpdates: [PendingSyncUpdate] = []
        for joiner in joiners {
            let dropsBefore = drops.count
            let viewFieldsBefore = drops.viewFields.count
            let (update, viewPatches) = planFullViewUpdate(
                state: state, recipient: joiner.recipient, staged: &plan.staged, stagedTables: &plan.stagedTables,
                stagedPerPlayerTables: &plan.stagedPerPlayerTables, drops: &drops,
                rowsFromStagedTables: true
            )
            joinerUpdates.append(update)
            if plan.digest != nil {
                var seed = SyncOutputDigestInput.SeedDigest(patches: viewPatches)
                if drops.count != dropsBefore { seed.drops.insert(.extraction) }
                seed.dropFields = Array(drops.viewFields[viewFieldsBefore...])
                plan.digest?.seeds[joiner.recipient.playerID] = seed
            }
        }
        // After the full views: their drops are this plan's extraction drops too.
        plan.digest?.noteDrops(drops)
        try plan.noteExtractionDrops(drops)
        try planPerPlayerFrames(
            pendingUpdates,
            recipients: recipients,
            events: events,
            into: &plan
        )
        if !joiners.isEmpty {
            try planJoinerFrames(joinerUpdates, joiners: joiners, events: events, into: &plan)
        }
        if rowAddressing && useStateUpdateWithEvents {
            // An unsynced recipient's view (not a resync's, which is tagged already): its frame
            // is the session's last state frame, after the shared one.
            for recipient in unsyncedRecipients where plan.syncLag.resyncs[recipient.sessionID] == nil {
                if let view = plan.frames.lastIndex(where: { $0.sessionID == recipient.sessionID && $0.isStateUpdate }) {
                    plan.frames[view].isFullViewBeforeSharedFrame = true
                }
            }
        }
        if useStateUpdateWithEvents && (!plan.syncLag.resyncs.isEmpty || rowAddressing) {
            plan.putResyncSnapshotsFirst()
        }

        if let extractStart, let extractEnd, let broadcastEnd {
            plan.phaseTimes = SyncPhaseTimes(
                extract: extractEnd - extractStart,
                broadcast: broadcastEnd - extractEnd,
                perPlayer: perPlayerTime,
                combined: !useStateUpdateWithEvents
            )
        }
        try syncPlanFaultForTesting?()
        return plan
    }

    /// `SyncEngine.lateJoinSnapshot`: a player's whole view, with the caches it seeds staged. On
    /// the typed tables a dropped broadcast field takes the tables' last-sent value, and unseeded
    /// tables are seeded from `state` (every field), as the empty broadcast cache is today.
    private func lateJoinSnapshot(
        for playerID: PlayerID,
        from state: State,
        staged: inout SyncEngine.StagedCaches,
        stagedTables: inout SyncTableStaged,
        stagedPerPlayerTables: inout SyncTablePerPlayerStaged,
        drops: inout ExtractionDrops
    ) -> StateSnapshot {
        guard let broadcastTables else {
            return syncEngine.lateJoinSnapshot(for: playerID, from: state, staged: &staged, drops: &drops)
        }
        let perPlayerTables = self.perPlayerTables
        let snapshot = syncEngine.lateJoinSnapshot(
            for: playerID,
            from: state,
            staged: &staged,
            drops: &drops,
            broadcastLastSent: { broadcastTables.lastSentSnapshot(of: $0) },
            perPlayerLastSent: perPlayerTables.map { tables in { tables.lastSentSnapshot(of: $0, for: playerID) } }
        )
        if !broadcastTables.isSeeded {
            broadcastTables.stageSeed(state, fields: nil, drops: &drops, into: &stagedTables)
        }
        // As today's seed of a player with neither a staged nor a committed per-player cache.
        perPlayerTables?.stageSeedIfAbsent(state, for: playerID, drops: &drops, into: &stagedPerPlayerTables)
        return snapshot
    }

    /// The whole view of a recipient whose client has none (its firstSync plan failed), as a
    /// diff from empty typed `.firstSync`, like `planFirstSync`. Stages the player's caches from
    /// `.all` snapshots and its firstSync mark.
    ///
    /// With row addressing each slot-addressed table is sent as its map's object and a create per
    /// row (`SyncTableBroadcastDiff.viewPatches`), from this plan's tables
    /// (`rowsFromStagedTables`) or the committed ones. Also returns the view's patches without
    /// that (the live view, as with the feature off), which the sync stream digests.
    private func planFullViewUpdate(
        state: State,
        recipient: SyncPhaseRecipient,
        staged: inout SyncEngine.StagedCaches,
        stagedTables: inout SyncTableStaged,
        stagedPerPlayerTables: inout SyncTablePerPlayerStaged,
        drops: inout ExtractionDrops,
        rowsFromStagedTables: Bool
    ) -> (update: PendingSyncUpdate, viewPatches: [StatePatch]) {
        let snapshot = lateJoinSnapshot(
            for: recipient.playerID, from: state, staged: &staged, stagedTables: &stagedTables,
            stagedPerPlayerTables: &stagedPerPlayerTables, drops: &drops
        )
        if let perPlayerTables {
            // Today's re-stage from an `.all` extraction, on the player's boxes.
            perPlayerTables.stageReseed(state, for: recipient.playerID, drops: &drops, into: &stagedPerPlayerTables)
        } else {
            staged.perPlayer[recipient.playerID] = syncEngine.extractPerPlayerSnapshot(
                for: recipient.playerID,
                from: state,
                mode: .all,
                drops: &drops
            )
        }
        staged.firstSyncReceived.insert(recipient.playerID)
        let patches = syncEngine.computeDiff(from: StateSnapshot(values: [:]), to: snapshot, onlyPaths: nil)
        var sent = patches
        if rowAddressing, let broadcastTables {
            sent = SyncPlanning.replacingRows(
                of: patches, with: broadcastTables.viewPatches(staged: stagedTables, useStaged: rowsFromStagedTables)
            )
        }
        let update = makePendingSyncUpdate(
            sessionID: recipient.sessionID,
            playerID: recipient.playerID,
            update: .firstSync(sent)
        )
        return (update, patches)
    }

    /// opcode 107: the merged broadcast frame for every recipient, carrying the queued broadcast
    /// events, when there is anything to send.
    /// With `resetsKeyScope` it is always planned, typed `.firstSync` (broadcast key scope reset).
    /// If its state doesn't encode, or its events don't pack into it, the plan throws and the
    /// land ends (#535 rows 10, 17).
    private func planMergedBroadcastFrame(
        broadcastDiff: [StatePatch],
        recipients: [SyncPhaseRecipient],
        events: PendingEventManager,
        resetsKeyScope: Bool,
        into plan: inout SyncPhasePlan
    ) throws {
        guard resetsKeyScope || !broadcastDiff.isEmpty || events.hasAnyEvents else {
            return
        }
        guard let first = recipients.first else {
            // No recipient (every member is in initial sync): drop the queued events, as before.
            // Initial-syncing players miss events of their join window even when another session
            // is a recipient; the boundary belongs at the firstSync snapshot (#69).
            plan.consumedEvents = SyncPhaseConsumedEvents(
                targeted: events.targetedEventCount,
                broadcast: events.broadcastEventCount
            )
            return
        }

        let broadcastUpdate: StateUpdate = resetsKeyScope
            ? .firstSync(broadcastDiff)
            : (broadcastDiff.isEmpty ? .noChange : .diff(broadcastDiff))
        let eventBodies = events.pendingBroadcastBodies()
        plan.consumedEvents.broadcast = events.broadcastEventCount
        let data = try encodeMergedBroadcastFrameOrFail(
            broadcastUpdate,
            playerID: first.playerID,
            eventBodies: eventBodies,
            into: &plan
        )
        for recipient in recipients {
            // The merged frame (opcode 107) is MessagePack: binary.
            plan.frames.append(SyncPhaseFrame(data: data, sessionID: recipient.sessionID, kind: .binary, isStateUpdate: true))
        }
        plan.stateUpdateCount += recipients.count
    }

    /// The land's failure for a state frame that didn't encode (#535 rows 8, 10, 11, 13 and 14):
    /// nothing is re-encoded with patches dropped. A path outside the schema is counted in
    /// `unmappedPathPatches` (D6).
    private func stateFrameEncodeFailure(_ error: any Error, what: String) -> LandFailure {
        if case StateUpdateEncodingError.pathNotInSchema = error {
            unmappedPathCounter.recordDroppedPatch()
        }
        return LandFailure(
            kind: .syncEncode,
            detail: "\(what): \(error)",
            position: LandFailurePosition(stage: .syncPhase)
        )
    }

    /// The merged broadcast frame, or the land's failure (#535 rows 9 and 12): a broadcast frame
    /// that doesn't encode is never re-encoded with patches dropped, and nothing is staged for it.
    private func encodeMergedBroadcastFrameOrFail(
        _ update: StateUpdate,
        playerID: PlayerID,
        eventBodies: [MessagePackValue],
        into plan: inout SyncPhasePlan
    ) throws -> Data {
        if !update.patchList.isEmpty {
            plan.encodesBroadcastPatches = true
        }
        do {
            return try encodeMergedBroadcastFrame(update: update, playerID: playerID, eventBodies: eventBodies)
        } catch let failure as LandFailure {
            throw failure
        } catch {
            throw stateFrameEncodeFailure(error, what: "broadcast frame")
        }
    }

    /// The broadcast state update merged with `eventBodies` (opcode 107), encoded once for every
    /// recipient. The fault hooks are the adapter's, evaluated in their order: the frame's before
    /// the encode, the pack's only after it.
    private func encodeMergedBroadcastFrame(
        update: StateUpdate,
        playerID: PlayerID,
        eventBodies: [MessagePackValue]
    ) throws -> Data {
        if let fault = mergedBroadcastFrameFaultForTesting, fault() {
            throw SyncPhaseInjectedEncodeFault()
        }
        let encoded = try encodingPipeline.encodeMergedBroadcastUpdate(update: update, playerID: playerID, syncSeq: planSyncSeq)
        return try encodingPipeline.mergeEvents(
            into: encoded,
            eventBodies: eventBodies,
            failsPack: mergedEventsPackFaultForTesting?() == true
        )
    }

    /// Per-player state frames in recipient order. With opcode 107 each recipient's targeted event
    /// frames come right before its per-player frame (alone when it has none), and the plan
    /// consumes the targeted events it read.
    ///
    /// An update that fails to encode ends the land (#535 rows 10, 11 and 13): the plan throws.
    /// The flipping joiners' frames, after everyone else's: per joiner its JoinResponse, then
    /// its firstSync (#69); the commit appends its held events. A firstSync that doesn't encode
    /// ends the land (#535 row 13): the plan throws.
    private func planJoinerFrames(
        _ updates: [PendingSyncUpdate],
        joiners: [SyncPhaseJoiner],
        events: PendingEventManager,
        into plan: inout SyncPhasePlan
    ) throws {
        // A flipping joiner is left out of this plan's merged broadcast frame and gets a
        // per-player firstSync only, so its broadcast key map ends empty, as after
        // `planFirstSync`: the commit requests the same key scope reset (#90).
        plan.needsBroadcastKeyReset = usesBroadcastKeyTable
        let start = plan.frames.count
        // A joiner's first view that doesn't encode ends the land (#535 row 13).
        try planPerPlayerFrames(updates, recipients: joiners.map(\.recipient), events: events, includesEvents: false, into: &plan)
        let firstSyncFrames = Array(plan.frames[start...])
        plan.frames.removeSubrange(start...)
        for joiner in joiners {
            let sessionID = joiner.recipient.sessionID
            let own = firstSyncFrames.filter { $0.sessionID == sessionID }
            // JSON, as in the handshake (`LandRouter` builds it with the JSON encoder).
            plan.frames.append(SyncPhaseFrame(data: joiner.joinResponse, sessionID: sessionID, kind: .text))
            plan.frames.append(contentsOf: own)
            plan.flips.append((sessionID: sessionID, ticket: joiner.ticket))
        }
    }

    private func planPerPlayerFrames(
        _ pendingUpdates: [PendingSyncUpdate],
        recipients: [SyncPhaseRecipient],
        events: PendingEventManager,
        includesEvents: Bool = true,
        into plan: inout SyncPhasePlan
    ) throws {
        var payloadBySession: [SessionID: Data] = [:]
        let (encoded, failures) = encodeUpdatesSerially(pendingUpdates)
        for update in encoded {
            payloadBySession[update.sessionID] = update.payload
        }
        if let firstFailure = failures.first {
            // Rows 10, 11 and 13 (#535): a player's frame that doesn't encode ends the land,
            // whatever it is (a diff, a resync snapshot, a first view). Nothing is re-encoded
            // with patches dropped.
            throw stateFrameEncodeFailure(
                firstFailure.error, what: "state frame for player \(firstFailure.playerID.rawValue)"
            )
        }

        let targetedEnd = useStateUpdateWithEvents ? events.targetedEventCount : 0
        if useStateUpdateWithEvents && includesEvents {
            plan.consumedEvents.targeted = targetedEnd
        }
        let hasTargetedEvents = includesEvents && useStateUpdateWithEvents && events.hasTargetedEvents
        for recipient in recipients {
            if hasTargetedEvents {
                let eventBodies = pendingTargetedEventBodies(
                    events: events,
                    for: recipient.sessionID,
                    playerID: recipient.playerID,
                    endingBefore: targetedEnd
                )
                try appendEventFrames(eventBodies, to: recipient.sessionID, into: &plan.frames)
            }
            if let payload = payloadBySession[recipient.sessionID] {
                plan.frames.append(SyncPhaseFrame(
                    data: payload, sessionID: recipient.sessionID, kind: stateUpdateEncoder.encoding.frameKind, isStateUpdate: true,
                    isResyncSnapshot: plan.syncLag.resyncs[recipient.sessionID] != nil
                ))
                plan.stateUpdateCount += 1
            }
        }
    }

    /// The plan's dirty fields when dirty tracking applies (`extractAll` off, tracking on, the
    /// state dirty), else nil: the argument `SyncPlanning`'s mode functions take.
    private func dirtyFieldsToDiff(_ state: State, extractAll: Bool) -> Set<String>? {
        guard !extractAll, enableDirtyTracking, planIsDirty(state) else { return nil }
        return planDirtyFields(of: state)
    }

    private func computeSyncModes(
        for state: State,
        extractAll: Bool
    ) -> (broadcastMode: SnapshotMode, perPlayerMode: SnapshotMode) {
        SyncPlanning.computeSyncModes(for: state, dirtyFields: dirtyFieldsToDiff(state, extractAll: extractAll))
    }

    private func modesBesideTables(
        for state: State,
        extractAll: Bool,
        broadcastMode: SnapshotMode,
        perPlayerMode: SnapshotMode
    ) -> (broadcast: SnapshotMode, perPlayer: SnapshotMode) {
        // The dirty fields are read only when the one-pass extraction uses them, as before.
        guard useSnapshotForSync else { return (broadcastMode, perPlayerMode) }
        return SyncPlanning.onePassModes(dirtyFields: dirtyFieldsToDiff(state, extractAll: extractAll))
    }

    private func extractSyncSnapshots(
        from state: State,
        recipients: [SyncPhaseRecipient],
        broadcastMode: SnapshotMode,
        perPlayerMode: SnapshotMode,
        extractAll: Bool,
        drops: inout ExtractionDrops
    ) -> (
        broadcastSnapshot: StateSnapshot,
        perPlayerByPlayer: [PlayerID: StateSnapshot],
        broadcastMode: SnapshotMode,
        perPlayerMode: SnapshotMode
    ) {
        // One entry per player, in recipient order (a player may have several sessions).
        var seenPlayers = Set<PlayerID>()
        let playerIDs = recipients.compactMap { seenPlayers.insert($0.playerID).inserted ? $0.playerID : nil }

        if broadcastTables != nil {
            // The broadcast diff already ran on the tables (its drops are in `drops`). The
            // per-player fields stay on today's path and must come out as it extracts them.
            let (broadcast, perPlayer) = modesBesideTables(
                for: state, extractAll: extractAll, broadcastMode: broadcastMode, perPlayerMode: perPlayerMode
            )
            if perPlayerTables != nil {
                // The per-player fields are diffed on the per-player tables (#514), with this mode.
                return (
                    broadcastSnapshot: StateSnapshot(values: [:]),
                    perPlayerByPlayer: [:],
                    broadcastMode: broadcast,
                    perPlayerMode: perPlayer
                )
            }
            perPlayerExtractionsForTesting += 1
            var perPlayerByPlayer: [PlayerID: StateSnapshot] = [:]
            // The one-pass extraction, per-player part: every per-player field of every player,
            // and no entry at all for a state without per-player fields. It fails as a whole
            // when any field it converts throws, a dirty broadcast field included, and then the
            // separate extraction below takes over, as in `extractWithSnapshotForSync`.
            if useSnapshotForSync, drops.broadcastFields.isEmpty {
                let perPlayerFields = Set(
                    state.getSyncFields().filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }.map(\.name)
                )
                var onePass: [PlayerID: StateSnapshot]? = [:]
                if !perPlayerFields.isEmpty {
                    for playerID in playerIDs {
                        // Only the per-player fields are converted: the broadcast ones were diffed above.
                        guard let snapshot = try? syncEngine.extractPerPlayerSnapshot(for: playerID, from: state, mode: .include(perPlayerFields)) else {
                            onePass = nil
                            break
                        }
                        onePass?[playerID] = snapshot
                    }
                }
                if let onePass {
                    return (
                        broadcastSnapshot: StateSnapshot(values: [:]),
                        perPlayerByPlayer: onePass,
                        broadcastMode: broadcast,
                        perPlayerMode: perPlayer
                    )
                }
            }
            perPlayerByPlayer.reserveCapacity(playerIDs.count)
            for playerID in playerIDs {
                perPlayerByPlayer[playerID] = syncEngine.extractPerPlayerSnapshot(
                    for: playerID,
                    from: state,
                    mode: perPlayer,
                    drops: &drops
                )
            }
            return (
                broadcastSnapshot: StateSnapshot(values: [:]),
                perPlayerByPlayer: perPlayerByPlayer,
                broadcastMode: broadcast,
                perPlayerMode: perPlayer
            )
        }

        perPlayerExtractionsForTesting += 1
        if useSnapshotForSync {
            let fullMode: SnapshotMode = (!extractAll && enableDirtyTracking && planIsDirty(state))
                ? .dirtyTracking(planDirtyFields(of: state))
                : .all
            let extracted = syncEngine.extractWithSnapshotForSync(
                from: state,
                playerIDs: playerIDs,
                mode: fullMode,
                drops: &drops
            )
            // One-pass extraction filters both broadcast and per-player fields against the same
            // `fullMode` dirty-field set, so the mode used for later diffing must be `fullMode` too
            // (not the independently-computed `broadcastMode`/`perPlayerMode`), or fields left out of
            // this extraction get compared as if they were still fully present in the previous snapshot.
            return (
                broadcastSnapshot: extracted.broadcast,
                perPlayerByPlayer: extracted.perPlayer,
                broadcastMode: fullMode,
                perPlayerMode: fullMode
            )
        }

        let broadcastSnapshot = syncEngine.extractBroadcastSnapshot(from: state, mode: broadcastMode, drops: &drops)
        var perPlayerByPlayer: [PlayerID: StateSnapshot] = [:]
        perPlayerByPlayer.reserveCapacity(playerIDs.count)
        for playerID in playerIDs {
            perPlayerByPlayer[playerID] = syncEngine.extractPerPlayerSnapshot(
                for: playerID,
                from: state,
                mode: perPlayerMode,
                drops: &drops
            )
        }
        return (
            broadcastSnapshot: broadcastSnapshot,
            perPlayerByPlayer: perPlayerByPlayer,
            broadcastMode: broadcastMode,
            perPlayerMode: perPlayerMode
        )
    }

    private func collectPerPlayerOnlyPendingUpdates(
        recipients: [SyncPhaseRecipient],
        perPlayerByPlayer: [PlayerID: StateSnapshot],
        perPlayerMode: SnapshotMode,
        baseline: SyncEngine.DiffBaseline,
        typesFirstSync: Bool,
        skipping skippedPlayers: Set<PlayerID>,
        staged: inout SyncEngine.StagedCaches
    ) -> [PendingSyncUpdate] {
        var pendingUpdates: [PendingSyncUpdate] = []
        pendingUpdates.reserveCapacity(recipients.count)

        for recipient in recipients where !skippedPlayers.contains(recipient.playerID) {
            guard let perPlayerSnapshot = perPlayerByPlayer[recipient.playerID] else {
                continue
            }

            var update = syncEngine.generatePerPlayerUpdateFromSnapshot(
                for: recipient.playerID,
                perPlayerSnapshot: perPlayerSnapshot,
                perPlayerMode: perPlayerMode,
                onlyPaths: nil,
                baseline: baseline,
                staged: &staged
            )
            if typesFirstSync {
                update = SyncPlanning.keyScopeResetUpdate(update)
            } else if case .noChange = update {
                continue
            }

            pendingUpdates.append(makePendingSyncUpdate(
                sessionID: recipient.sessionID,
                playerID: recipient.playerID,
                update: update
            ))
        }

        return pendingUpdates
    }

    /// The per-recipient updates with the per-player fields diffed on the per-player tables
    /// (#514), as `collectPerPlayerOnlyPendingUpdates` (no `broadcastDiff`) and
    /// `collectCombinedPendingUpdates` build them from today's snapshots:
    /// - each player is diffed once, by its first recipient in recipient order; its later
    ///   sessions get the update built from no per-player patches, as today's diff against the
    ///   first one's staged cache yields (#531);
    /// - with the one-pass branch a state without per-player fields has no per-player entry, so a
    ///   per-player-only update isn't made at all; the separate branch has one per player;
    /// - the fields diffed are those `perPlayerMode` compares, and a player without boxes is
    ///   seeded (every field with the one-pass branch, as its extraction).
    private func collectPerPlayerTablePendingUpdates(
        _ perPlayerTables: SyncTablePerPlayerDiff<State>,
        state: State,
        recipients: [SyncPhaseRecipient],
        broadcastDiff: [StatePatch]?,
        perPlayerMode: SnapshotMode,
        onePass: Bool,
        baseline: SyncEngine.DiffBaseline,
        typesFirstSync: Bool,
        skipping skippedPlayers: Set<PlayerID>,
        drops: inout ExtractionDrops,
        plan: inout SyncPhasePlan
    ) -> [PendingSyncUpdate] {
        var pendingUpdates: [PendingSyncUpdate] = []
        pendingUpdates.reserveCapacity(recipients.count)
        let hasEntries = !onePass || !perPlayerTables.fieldNames.isEmpty
        // The tables need the delta strategy, whose baseline is `.cached` (a key reset only
        // retypes the update); `.empty` is the full-snapshot strategy's.
        if case .empty = baseline { assertionFailure("the per-player tables diffed against the .empty baseline") }
        var diffed = Set<PlayerID>()
        // Once per sync, not per recipient (#392).
        let broadcastIndex = broadcastDiff.map(SyncEngine.BroadcastMergeIndex.init)

        for recipient in recipients where !skippedPlayers.contains(recipient.playerID) {
            var perPlayerDiff: [StatePatch] = []
            if hasEntries, diffed.insert(recipient.playerID).inserted {
                perPlayerDiff = perPlayerTables.planDiff(
                    state, for: recipient.playerID, fields: perPlayerMode.fields, seedsAll: onePass,
                    drops: &drops, into: &plan.stagedPerPlayerTables
                )
            }
            var update: StateUpdate
            if let broadcastIndex {
                update = syncEngine.updateFromBroadcastDiff(
                    for: recipient.playerID, broadcastDiff: broadcastIndex, perPlayerDiff: perPlayerDiff, staged: &plan.staged
                )
            } else {
                guard hasEntries else { continue }
                update = perPlayerDiff.isEmpty ? .noChange : .diff(perPlayerDiff)
            }
            if typesFirstSync {
                update = SyncPlanning.keyScopeResetUpdate(update)
            } else if case .noChange = update {
                continue
            }
            pendingUpdates.append(makePendingSyncUpdate(
                sessionID: recipient.sessionID,
                playerID: recipient.playerID,
                update: update
            ))
        }
        return pendingUpdates
    }

    private func collectCombinedPendingUpdates(
        recipients: [SyncPhaseRecipient],
        broadcastDiff: [StatePatch],
        perPlayerByPlayer: [PlayerID: StateSnapshot],
        perPlayerMode: SnapshotMode,
        baseline: SyncEngine.DiffBaseline,
        typesFirstSync: Bool,
        skipping skippedPlayers: Set<PlayerID>,
        staged: inout SyncEngine.StagedCaches
    ) -> [PendingSyncUpdate] {
        var pendingUpdates: [PendingSyncUpdate] = []
        pendingUpdates.reserveCapacity(recipients.count)

        for recipient in recipients where !skippedPlayers.contains(recipient.playerID) {
            let perPlayerSnapshot = perPlayerByPlayer[recipient.playerID] ?? StateSnapshot(values: [:])
            var update = syncEngine.generateUpdateFromBroadcastDiff(
                for: recipient.playerID,
                broadcastDiff: broadcastDiff,
                perPlayerSnapshot: perPlayerSnapshot,
                perPlayerMode: perPlayerMode,
                onlyPaths: nil,
                baseline: baseline,
                staged: &staged
            )
            if typesFirstSync {
                update = SyncPlanning.keyScopeResetUpdate(update)
            } else if case .noChange = update {
                continue
            }

            pendingUpdates.append(makePendingSyncUpdate(
                sessionID: recipient.sessionID,
                playerID: recipient.playerID,
                update: update
            ))
        }

        return pendingUpdates
    }

    private func makePendingSyncUpdate(
        sessionID: SessionID,
        playerID: PlayerID,
        update: StateUpdate
    ) -> PendingSyncUpdate {
        let (updateType, patchCount) = update.typeAndPatchCount()
        let playerSlot = getPlayerSlot(for: playerID)
        return PendingSyncUpdate(
            sessionID: sessionID,
            playerID: playerID,
            playerSlot: playerSlot,
            update: update,
            updateType: updateType,
            patchCount: patchCount
        )
    }

    /// Number of queued targeted and broadcast events (for tests).
    func pendingEventCounts() -> (targeted: Int, broadcast: Int) {
        (pendingEventManager.targetedEventCount, pendingEventManager.broadcastEventCount)
    }

    /// The keeper's broadcast-only request (`syncBroadcastOnlyFromTransport`): one sync-only turn
    /// on the keeper, now, as `_syncNowImpl` (#546 L2b). A full phase covers broadcast-only
    /// changes. A frozen land's turn leaves its sync to the resume, so the request defers once,
    /// through the keeper. Like any requested turn, it can still run between an output gate's
    /// close and its failure submit and flip a waiting join there (pre-existing, #704).
    func _syncBroadcastOnlyImpl() async {
        _ = await keeper.syncTurnNow(via: self, reason: .broadcastOnly)
    }

    /// `withoutDroppedFields` for every pending update, each filtered by the per-player fields
    /// dropped for its own player (its broadcast patches were filtered with the broadcast diff).
    /// An update left with no change is not sent (one typed `.firstSync` is kept: it may reset a
    /// key scope).
    private func withoutDroppedFields(
        _ updates: [PendingSyncUpdate],
        drops: ExtractionDrops,
        baseline: SyncEngine.DiffBaseline
    ) -> [PendingSyncUpdate] {
        guard case .empty = baseline, !drops.perPlayerFields.isEmpty else { return updates }
        return updates.compactMap { pending in
            guard let dropped = drops.perPlayerFields[pending.playerID], !dropped.isEmpty else {
                return pending
            }
            let update: StateUpdate
            switch pending.update {
            case .noChange:
                return pending
            case .firstSync(let patches):
                update = .firstSync(SyncPlanning.withoutDroppedFields(patches, dropped: dropped, baseline: baseline))
            case .diff(let patches):
                let kept = SyncPlanning.withoutDroppedFields(patches, dropped: dropped, baseline: baseline)
                guard !kept.isEmpty else { return nil }
                update = .diff(kept)
            }
            return makePendingSyncUpdate(sessionID: pending.sessionID, playerID: pending.playerID, update: update)
        }
    }

    // MARK: - Encoding Support

    
    
    /// Encode updates serially. Every update is attempted, so a failure is attributed to exactly
    /// the recipients whose update failed.
    private func encodeUpdatesSerially(
        _ pendingUpdates: [PendingSyncUpdate]
    ) -> (encoded: [EncodedSyncUpdate], failures: [SyncPhaseEncodeFailure]) {
        var encoded: [EncodedSyncUpdate] = []
        encoded.reserveCapacity(pendingUpdates.count)
        var failures: [SyncPhaseEncodeFailure] = []
        for pending in pendingUpdates {
            do {
                let data = try encodePerPlayerUpdate(pending.update, playerID: pending.playerID, playerSlot: pending.playerSlot)
                encoded.append(EncodedSyncUpdate(
                    sessionID: pending.sessionID,
                    playerID: pending.playerID,
                    updateType: pending.updateType,
                    patchCount: pending.patchCount,
                    payload: data
                ))
            } catch {
                failures.append(SyncPhaseEncodeFailure(
                    sessionID: pending.sessionID,
                    playerID: pending.playerID,
                    error: error
                ))
            }
        }
        return (encoded, failures)
    }

    /// Encodes a per-player state update (per-player key scope).
    private func encodePerPlayerUpdate(_ update: StateUpdate, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        if let fault = syncEncodeFaultForTesting, fault(playerID) {
            throw SyncPhaseInjectedEncodeFault()
        }
        return try encodingPipeline.encodePerPlayerUpdate(
            update,
            playerID: playerID,
            playerSlot: playerSlot,
            syncSeq: planSyncSeq,
            resync: planSyncSeq != nil && planResyncPlayers.contains(playerID)
        )
    }

    /// Records a sampled sync plan duration (1 in 100) as the profiler's encode latency.
    private func recordEncodeSample(_ duration: Duration) {
        guard let profiler else { return }
        let encodeMs = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        latencySampleCounter += 1
        if latencySampleCounter % 100 == 0 {
            Task { await profiler.recordEncode(durationMs: encodeMs) }
        }
    }

    /// Internal implementation of syncStateForNewPlayer without initialSyncingPlayers management.
    /// Caller is responsible for managing initialSyncingPlayers.
    ///
    /// Plan + commit like a sync cycle. A failed plan commits nothing, so the player stays unmarked
    /// and the next full cycle gives it its whole view (`planFullViewUpdate`).
    private func _syncStateForNewPlayer(playerID: PlayerID, sessionID: SessionID, ticket: Ticket<SessionID>) async {
        if rowAddressing {
            // Every join of such a land completes in a turn, and its firstSync comes from a
            // broadcast plan: a standalone one would bind rows outside the plans that number them.
            assertionFailure("a standalone firstSync on a land with row addressing in effect")
            logger.error("Join refused: its firstSync would be standalone, on a land with row addressing in effect", metadata: [
                "landID": .string(landID),
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
            ])
            await transport.closeSession(
                sessionID, with: SessionClose(code: 1011, reason: "join did not complete in a turn"),
                generation: connectionGenerations[sessionID]
            )
            return
        }
        await holds.at(.initialSync)
        let commitsBeforeRead = syncPhaseCommits
        // One keeper job for the state and where it was read (`currentStateLocated`).
        let located = await keeper.currentStateLocated()
        let state = located.state
        let read = located.recordsSyncStream ? SyncOutputRead(turnKind: .legacyCycle, position: located.position) : nil
        await holds.at(.initialSyncAfterRead)
        // The session's ticket, and its membership as `playerID`, are checked after the state
        // read, in the same synchronous segment as the commit: a disconnect, supersede or rebind
        // during the read ended the ticket (and a disconnect cleared the player's state), and
        // committing now would re-create its cache, firstSync mark and recorder seed for a
        // session that is gone or bound to another player.
        guard sessionTickets.isCurrent(ticket),
              membershipCoordinator.playerID(for: sessionID) == playerID else {
            initialSyncsDroppedStale += 1
            logger.info("Initial sync dropped: the session left during it", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "playerID": .string(playerID.rawValue),
            ])
            return
        }
        // The land failed during the read (#535): its output gate is closed, so this firstSync
        // is never sent. Return before planning, so nothing of it is committed or recorded.
        guard !outputGate.isClosed else {
            initialSyncsDroppedLandFailed += 1
            logger.info("Initial sync dropped: the land failed during its state read", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "playerID": .string(playerID.rawValue),
            ])
            return
        }
        // A sync phase committed during the read: a cycle that skipped this player may have
        // moved the broadcast cache past the read, and the next diff starts from the cache, so a
        // firstSync from the read would leave this client behind on the fields that changed in
        // between (#564). The player stays unmarked, so the next cycle sends its whole view from
        // that cycle's own state; without periodic sync a follow-up runs that cycle. One drop is
        // enough: that view and the broadcast cache it leaves come from the same plan and commit,
        // so they can't diverge. Every commit counts, another player's firstSync too, which may
        // drop a read that was still current: conservative, the view only comes a cycle later.
        guard syncPhaseCommits == commitsBeforeRead else {
            initialSyncsDroppedBehindCommit += 1
            logger.info("Initial sync dropped: a sync committed during its state read; the next cycle sends the whole view", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "playerID": .string(playerID.rawValue),
            ])
            // The failed-plan follow-up, not counted as a failed plan: nothing failed, and one
            // drop happens per join at most.
            if !keeper.hasPeriodicSync { startDelayedFollowUpSync() }
            return
        }
        do {
            try runSyncPhase(isSyncCycle: false, read: read) {
                try planFirstSync(state: state, playerID: playerID, sessionID: sessionID)
            }
        } catch {
            logger.error("Initial sync failed: the land ends", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
            // Row 16 (#535): a joiner's view that doesn't convert or encode, or a plan that
            // throws, ends the land, as a cycle's does: no retry, no follow-up.
            let failure = error as? LandFailure ?? LandFailure(
                kind: .syncPlan,
                detail: String(describing: error),
                position: LandFailurePosition(stage: .syncPhase)
            )
            await failOutsideTurn(failure)
        }
    }

    /// Plan of a joining player's firstSync: its complete view as a diff from empty.
    private func planFirstSync(state: State, playerID: PlayerID, sessionID: SessionID) throws -> SyncPhasePlan {
        try firstSyncPlanFaultForTesting?()
        // See `_syncStateForNewPlayer`: no path reaches here with row addressing in effect.
        guard !rowAddressing else {
            assertionFailure("a standalone firstSync plan on a land with row addressing in effect")
            throw StandaloneFirstSyncRefused()
        }
        var plan = makePlan()
        plan.syncLag.firstSyncSession = sessionID
        plan.digest?.isFirstSync = true
        // Extract a complete snapshot for this player; stage the cache population.
        var drops = ExtractionDrops()
        let snapshot = lateJoinSnapshot(
            for: playerID, from: state, staged: &plan.staged, stagedTables: &plan.stagedTables,
            stagedPerPlayerTables: &plan.stagedPerPlayerTables, drops: &drops
        )
        try plan.noteExtractionDrops(drops)

        // Generate full patch set (assume client starts from empty state)
        // This is effectively a "diff from empty" -> series of .set operations
        let patches = syncEngine.computeDiff(
            from: StateSnapshot(values: [:]),
            to: snapshot,
            onlyPaths: nil
        )

        // Wrap in firstSync to trigger Force Definition in Encoder
        let update = StateUpdate.firstSync(patches)
        if plan.digest != nil {
            var seed = SyncOutputDigestInput.SeedDigest(patches: patches)
            if drops.count > 0 { seed.drops.insert(.extraction) }
            seed.dropFields = drops.viewFields
            plan.digest?.seeds[playerID] = seed
        }

        // Encode using the shared stateUpdateEncoder
        // Thread-safe DynamicKeyTable ensures no corruption during concurrent access
        // .firstSync triggers "Define-on-first-use" for correct client mapping
        let playerSlot = getPlayerSlot(for: playerID)
        let updateData: Data
        do {
            updateData = try encodePerPlayerUpdate(update, playerID: playerID, playerSlot: playerSlot)
        } catch {
            // Row 13 (#535): a joiner's first view that doesn't encode ends the land.
            throw stateFrameEncodeFailure(error, what: "first view for player \(playerID.rawValue)")
        }

        // Only compute logging metadata if debug logging is enabled
        if logger.logLevel <= .debug {
            logger.debug("📤 Sending initial state (firstSync)", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "bytes": .string("\(updateData.count)"),
                "patches": .string("\(patches.count)")
            ])
        }

        // Log update preview (first 500 chars) - only compute if trace logging is enabled
        if let preview = logger.safePreview(from: updateData, maxLength: 500) {
            logger.trace("📤 FirstSync preview", metadata: [
                "playerID": .string(playerID.rawValue),
                "preview": .string(preview)
            ])
        }

        plan.frames = [SyncPhaseFrame(data: updateData, sessionID: sessionID, kind: stateUpdateEncoder.encoding.frameKind, isStateUpdate: true)]
        plan.stateUpdateCount = 1
        // Marked as synced in the commit, so subsequent updates use diffs.
        plan.staged.firstSyncReceived.insert(playerID)
        // This firstSync defined keys in the player's per-player scope only (#90).
        plan.needsBroadcastKeyReset = usesBroadcastKeyTable

        try syncPlanFaultForTesting?()
        return plan
    }

    /// Sync state for a new player (first connection) using firstSync (OpArray format).
    /// This sends the complete initial state as a series of patches (with compressed keys).
    /// Automatically manages initialSyncingPlayers to prevent concurrent diff updates.
    public func syncStateForNewPlayer(playerID: PlayerID, sessionID: SessionID) async {
        _ = await withInitialSync(for: playerID, sessionID: sessionID) { ticket in
            await _syncStateForNewPlayer(playerID: playerID, sessionID: sessionID, ticket: ticket)
        }
    }

    /// Handle action request from client
    private func handleActionRequest(
        requestID: String,
        envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async {
        // Every answer to this request, an ACK, a response or an error, is sent only while this
        // ticket is current: a disconnect ends it, so a reconnect that reuses the SessionID never
        // gets the old connection's answer.
        let ticket = actionResponseTickets.ticket(for: sessionID) ?? actionResponseTickets.issue(sessionID)
        do {
            let typeIdentifier = envelope.typeIdentifier
            let handleStart = ContinuousClock.now

            // Submitted on the inbound chain; an action with resolvers on a tick land comes back
            // pending, and is answered from a tracked task, so the chain moves on.
            let response: InputOutcome
            switch try await keeper.submitAction(
                envelope,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID
            ) {
            case .completed(let completed):
                response = completed
            case .pending(let sequence):
                trackActionResponse(
                    sequence: sequence,
                    ticket: ticket,
                    requestID: requestID,
                    envelope: envelope,
                    playerID: playerID,
                    sessionID: sessionID,
                    handleStart: handleStart
                )
                return
            }

            profilerCounters?.incrementActions()
            await recordProfiling(startTime: handleStart, operation: .handle)

            if let failure = sendActionResponse(
                requestID: requestID,
                actionType: typeIdentifier,
                response: response,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            ) {
                await submitNotedFailure(failure)
            }
        } catch {
            if let failure = handleActionError(
                error: error,
                requestID: requestID,
                envelope: envelope,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            ) {
                await submitNotedFailure(failure)
            }
        }
    }
    
    /// Starts the task that answers the pending job `sequence`. It always reads the job's slot
    /// once (so the keeper never keeps it), and answers only while `ticket` is current. Called
    /// in the segment `submitAction` returned in; if the session disconnected during that
    /// await, the task is cancelled at once and not tracked.
    private func trackActionResponse(
        sequence: Int64,
        ticket: Ticket<SessionID>,
        requestID: String,
        envelope: ActionEnvelope,
        playerID: PlayerID,
        sessionID: SessionID,
        handleStart: ContinuousClock.Instant
    ) {
        let keeper = self.keeper
        let task = Task { [weak self] in
            let outcome: Result<InputOutcome, any Error>
            do {
                outcome = .success(try await keeper.awaitActionResult(sequence: sequence))
            } catch {
                outcome = .failure(error)
            }
            await self?.finishActionResponse(
                sequence: sequence,
                ticket: ticket,
                outcome: outcome,
                requestID: requestID,
                envelope: envelope,
                playerID: playerID,
                sessionID: sessionID,
                handleStart: handleStart
            )
        }
        guard actionResponseTickets.isCurrent(ticket) else {
            task.cancel()
            return
        }
        actionResponseTasks[sessionID, default: [:]][sequence] = task
    }

    /// A pending job's outcome: answered if the session's ticket is still current.
    private func finishActionResponse(
        sequence: Int64,
        ticket: Ticket<SessionID>,
        outcome: Result<InputOutcome, any Error>,
        requestID: String,
        envelope: ActionEnvelope,
        playerID: PlayerID,
        sessionID: SessionID,
        handleStart: ContinuousClock.Instant
    ) async {
        await holds.at(.actionResponse)
        defer { noteActionResponseFinished() }
        guard actionResponseTickets.isCurrent(ticket) else { return }
        // Sequences are unique per keeper, so this entry is this task's.
        actionResponseTasks[sessionID]?.removeValue(forKey: sequence)
        if actionResponseTasks[sessionID]?.isEmpty == true {
            actionResponseTasks.removeValue(forKey: sessionID)
        }
        switch outcome {
        case .success(let response):
            profilerCounters?.incrementActions()
            await recordProfiling(startTime: handleStart, operation: .handle)
            // Checked again after that await, in the send's own segment.
            if let failure = sendActionResponse(
                requestID: requestID,
                actionType: envelope.typeIdentifier,
                response: response,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            ) {
                await submitNotedFailure(failure)
            }
        case .failure(let error):
            if let failure = handleActionError(
                error: error,
                requestID: requestID,
                envelope: envelope,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            ) {
                await submitNotedFailure(failure)
            }
        }
    }

    private func noteActionResponseFinished() {
        actionResponsesFinished += 1
        let ready = actionResponsesFinishedWaiters.filter { $0.value.count <= actionResponsesFinished }
        for (id, waiter) in ready {
            actionResponsesFinishedWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    /// Tests only: returns once `count` pending answers have finished (sent or dropped), or when
    /// the waiting task is cancelled, so a count that is never reached doesn't leave the waiter
    /// suspended past its test (#555). Each waiter is removed under the adapter's isolation and
    /// resumed exactly once.
    ///
    /// - Parameter registered: called once the waiter is stored (not when it returns at once or
    ///   is cancelled first), so a test acts after registration rather than after a delay. It has
    ///   finished by the time the waiter returns.
    func waitForActionResponsesFinishedForTesting(_ count: Int, registered: @escaping @Sendable () async -> Void = {}) async {
        guard actionResponsesFinished < count else { return }
        let id = nextActionResponsesFinishedWaiter
        nextActionResponsesFinishedWaiter += 1
        // Joined before returning, so the acknowledgement has run when the waiter returns.
        var acknowledgement: Task<Void, Never>?
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                actionResponsesFinishedWaiters[id] = (count, continuation)
                acknowledgement = Task { await registered() }
            }
        } onCancel: {
            Task { await self.cancelActionResponsesFinishedWaiter(id) }
        }
        await acknowledgement?.value
    }

    private func cancelActionResponsesFinishedWaiter(_ id: Int) {
        actionResponsesFinishedWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    /// Tests only: the action response tasks still tracked, over all sessions.
    func actionResponseTaskCountForTesting() -> Int {
        actionResponseTasks.values.reduce(0) { $0 + $1.count }
    }

    /// Send successful action response to client, if `ticket` is still current (checked in
    /// the same segment as the enqueue).
    ///
    /// A response that doesn't encode (a value that isn't a payload type on a compressed
    /// encoding, #544) would leave its client without an answer: the land ends. The output gate
    /// closes here, in this segment, and the caller submits the returned failure to the keeper.
    /// A response that reaches this helper is encoded before its ticket is checked, so a stale
    /// request's response that doesn't encode ends the land too: the failure is in the type,
    /// and the next current response of that type would fail the same way. A pending response
    /// whose ticket is already stale in `finishActionResponse` returns before this helper runs.
    private func sendActionResponse(
        requestID: String,
        actionType: String,
        response: InputOutcome,
        playerID: PlayerID,
        sessionID: SessionID,
        ticket: Ticket<SessionID>
    ) -> LandFailure? {
        do {
            // From the outcome, so the response isn't boxed on its way to the frame (#700 K1a);
            // an encoder without that entry gets the boxed message, with the same bytes.
            let responseData: Data
            if let actionResponseEncoder {
                responseData = try actionResponseEncoder.encodeActionResponse(requestID: requestID, outcome: response)
            } else {
                boxedActionResponsesForTesting += 1
                responseData = try messageEncoder.encode(
                    TransportMessage.actionResponse(requestID: requestID, response: response.boundaryValue)
                )
            }

            // Only compute logging metadata if info logging is enabled
            if logger.logLevel <= .info {
                logger.info("📤 Sending action response", metadata: [
                    "requestID": .string(requestID),
                    "actionType": .string(actionType),
                    "playerID": .string(playerID.rawValue),
                    "sessionID": .string(sessionID.rawValue),
                    "bytes": .string("\(responseData.count)")
                ])
            }

            // Log response payload - only compute if trace logging is enabled
            if let preview = logger.safePreview(from: responseData, maxLength: 500) {
                logger.trace("📤 Action response payload", metadata: [
                    "requestID": .string(requestID),
                    "actionType": .string(actionType),
                    "response": .string(preview)
                ])
            }

            let sent: Void? = actionResponseTickets.ifCurrent(ticket) { _ in
                enqueueOutbound(responseData, to: sessionID, kind: messageEncoder.encoding.frameKind)
            }
            if sent == nil { droppedStaleActionAnswer(requestID: requestID, sessionID: sessionID) }
            return nil
        } catch {
            logger.error("❌ Action response did not encode; the land ends", metadata: [
                "requestID": .string(requestID),
                "actionType": .string(actionType),
                "error": .string("\(error)")
            ])
            let failure = LandFailure(
                kind: .responseEncode,
                detail: "the response to action \(actionType) did not encode: \(error)",
                position: LandFailurePosition(stage: .actionResponse)
            )
            closeAndNoteOutsideTurn(failure)
            return failure
        }
    }
    
    /// Ends the land with a failure found outside a keeper turn (#704): closes the output gate
    /// and notes the failure on the keeper in this segment, then submits it. Every adapter-side
    /// close outside a turn goes through here or `closeAndNoteOutsideTurn` (the census in
    /// `scripts/gate-close-census.sh` pins that).
    func failOutsideTurn(_ failure: LandFailure) async {
        closeAndNoteOutsideTurn(failure)
        await submitNotedFailure(failure)
    }

    /// The synchronous half of `failOutsideTurn`, for a caller that closes in one segment and
    /// submits later. From here no frame of this land is enqueued (`enqueueFrames`), and the
    /// keeper's next step ends the land with `failure` before anything of that step goes out
    /// (`LandKeeper.notePendingFailure`), whichever adapter it runs through.
    func closeAndNoteOutsideTurn(_ failure: LandFailure) {
        outputGate.close(failure)
        keeper.notePendingFailure(failure)
    }

    /// Submits a failure already noted on the keeper (`closeAndNoteOutsideTurn`). It wakes a
    /// keeper with no turn due; a keeper that ran a step since the note has already failed, and
    /// keeps the first cause.
    private func submitNotedFailure(_ failure: LandFailure) async {
        await holds.at(.failureSubmit)
        await keeper.submitLandFailure(failure)
    }

    /// Handle action processing error and send error response, if `ticket` is still current
    /// (checked in the same segment as the enqueue).
    ///
    /// An error reply that doesn't encode would leave its client without an answer, as a
    /// response would (`sendActionResponse`): the land ends (#691). The output gate closes here,
    /// in this segment, and the caller submits the returned failure to the keeper. As for a
    /// response, a reply that reaches this helper is encoded before its ticket is checked, so a
    /// stale request's reply that doesn't encode ends the land too.
    private func handleActionError(
        error: Error,
        requestID: String,
        envelope: ActionEnvelope,
        playerID: PlayerID,
        sessionID: SessionID,
        ticket: Ticket<SessionID>
    ) -> LandFailure? {
        profilerCounters?.incrementErrors()
        logger.error("❌ Failed to handle action", metadata: [
            "requestID": .string(requestID),
            "actionType": .string(envelope.typeIdentifier),
            "playerID": .string(playerID.rawValue),
            "error": .string("\(error)")
        ])

        do {
            let (errorCode, errorMessage) = AdapterErrorMapping.mapActionError(error, actionType: envelope.typeIdentifier)
            let errorPayload = ErrorPayload(
                code: errorCode,
                message: errorMessage,
                details: [
                    "requestID": AnyCodable(requestID),
                    "actionType": AnyCodable(envelope.typeIdentifier)
                ]
            )
            let errorResponse = TransportMessage.error(errorPayload)
            if errorReplyEncodingFaultForTesting {
                throw EncodingError.invalidValue(
                    errorResponse, .init(codingPath: [], debugDescription: "encoding fault (tests)")
                )
            }
            let errorData = try messageEncoder.encode(errorResponse)
            let sent: Void? = actionResponseTickets.ifCurrent(ticket) { _ in
                enqueueOutbound(errorData, to: sessionID, kind: messageEncoder.encoding.frameKind)
            }
            if sent == nil { droppedStaleActionAnswer(requestID: requestID, sessionID: sessionID) }
            return nil
        } catch {
            logger.error("❌ Action error reply did not encode; the land ends", metadata: [
                "requestID": .string(requestID),
                "actionType": .string(envelope.typeIdentifier),
                "error": .string("\(error)")
            ])
            let failure = LandFailure(
                kind: .responseEncode,
                detail: "the error reply to action \(envelope.typeIdentifier) did not encode: \(error)",
                position: LandFailurePosition(stage: .actionResponse)
            )
            closeAndNoteOutsideTurn(failure)
            return failure
        }
    }
    
    /// An answer for a connection that ended before it was sent (its ticket ended).
    private func droppedStaleActionAnswer(requestID: String, sessionID: SessionID) {
        if logger.logLevel <= .debug {
            logger.debug("Action answer dropped: its connection ended", metadata: [
                "requestID": .string(requestID),
                "sessionID": .string(sessionID.rawValue),
            ])
        }
    }

    /// Handle join request from client
    private func handleJoinRequest(
        requestID: String,
        landID: String,
        sessionID: SessionID,
        requestedPlayerID: String?,
        deviceID: String?,
        metadata: [String: AnyCodable]?
    ) async {
        guard let clientID = await validateJoinRequest(
            requestID: requestID,
            requestLandID: landID,
            sessionID: sessionID,
            requestedPlayerID: requestedPlayerID,
            metadata: metadata
        ) else {
            return
        }

        let (playerSession, jwtAuthInfo) = prepareJoinRequestContext(
            sessionID: sessionID,
            clientID: clientID,
            requestedPlayerID: requestedPlayerID,
            deviceID: deviceID,
            metadata: metadata
        )

        // A duplicate login is handled in the admission segment (newest wins, `admitJoining`).
        await finalizeJoinRequest(
            requestID: requestID,
            sessionID: sessionID,
            clientID: clientID,
            playerSession: playerSession,
            jwtAuthInfo: jwtAuthInfo
        )
    }

    private func validateJoinRequest(
        requestID: String,
        requestLandID: String,
        sessionID: SessionID,
        requestedPlayerID: String?,
        metadata: [String: AnyCodable]?
    ) async -> ClientID? {
        guard let clientID = membershipCoordinator.clientID(for: sessionID) else {
            logger.warning("Join request from unknown session: \(sessionID.rawValue)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinSessionNotConnected,
                message: "Session not connected"
            )
            return nil
        }

        if membershipCoordinator.hasPlayer(sessionID: sessionID) {
            logger.warning("Join request from already joined session: \(sessionID.rawValue)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinAlreadyJoined,
                message: "Already joined"
            )
            return nil
        }

        guard requestLandID == self.landID else {
            logger.warning("Join request with mismatched landID: expected=\(self.landID), received=\(requestLandID)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinLandIDMismatch,
                message: "Land ID mismatch",
                details: [
                    "expected": AnyCodable(self.landID),
                    "received": AnyCodable(requestLandID)
                ]
            )
            return nil
        }

        if let expected = expectedSchemaHash {
            let clientSchemaHash = metadata?["schemaHash"]?.base as? String
            if clientSchemaHash != expected {
                logger.warning("Join request with mismatched schemaHash: expected=\(expected), received=\(clientSchemaHash ?? "nil")")
                await sendJoinError(
                    requestID: requestID,
                    sessionID: sessionID,
                    code: .joinSchemaHashMismatch,
                    message: "Schema version mismatch",
                    details: [
                        "expected": AnyCodable(expected),
                        "received": AnyCodable(clientSchemaHash ?? "nil")
                    ]
                )
                return nil
            }
        }

        if let missing = StateUpdateFeatureNegotiation.missingStateUpdateFeatures(required: stateUpdateFeatures, metadata: metadata) {
            logger.warning("Join request without required state-update features: missing=\(missing)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinStateUpdateFeatureMissing,
                message: StateUpdateFeatureNegotiation.missingFeaturesMessage(missing),
                details: [
                    "required": AnyCodable(stateUpdateFeatures),
                    "missing": AnyCodable(missing)
                ]
            )
            return nil
        }

        // An authenticated session joins as its token's player; on a land that authenticates
        // players, a session without a token can't name one (#209).
        if let rejection = Self.joinIdentityRejection(
            requestedPlayerID: requestedPlayerID,
            authInfo: membershipCoordinator.authInfo(for: sessionID),
            authenticatesPlayers: authenticatesPlayers
        ) {
            rejection.log(logger, sessionID: sessionID, requestedPlayerID: requestedPlayerID)
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinPlayerMismatch,
                message: rejection.message
            )
            return nil
        }

        return clientID
    }

    private func prepareJoinRequestContext(
        sessionID: SessionID,
        clientID: ClientID,
        requestedPlayerID: String?,
        deviceID: String?,
        metadata: [String: AnyCodable]?
    ) -> (playerSession: PlayerSession, jwtAuthInfo: AuthenticatedInfo?) {
        let jwtAuthInfo = membershipCoordinator.authInfo(for: sessionID)
        let playerSession = preparePlayerSession(
            sessionID: sessionID,
            clientID: clientID,
            requestedPlayerID: requestedPlayerID,
            deviceID: deviceID,
            metadata: metadata,
            authInfo: jwtAuthInfo
        )

        if let jwtAuthInfo = jwtAuthInfo, logger.logLevel <= .debug {
            logger.debug("Using JWT payload for join", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "jwtPlayerID": .string(jwtAuthInfo.playerID),
                "jwtMetadataCount": .string("\(jwtAuthInfo.metadata.count)"),
                "finalPlayerID": .string(playerSession.playerID),
                "finalMetadataCount": .string("\(playerSession.metadata.count)")
            ])
        }

        return (playerSession, jwtAuthInfo)
    }

    private func finalizeJoinRequest(
        requestID: String,
        sessionID: SessionID,
        clientID: ClientID,
        playerSession: PlayerSession,
        jwtAuthInfo: AuthenticatedInfo?
    ) async {
        var joinSucceeded = false
        var playerID: PlayerID?
        // The connection this join is for, read before the join's await: a supersede's final
        // frame and close must not reach a later connection under the ID (#947). `nil` while the
        // session isn't registered yet: the close then goes to the ID's connection at the time.
        let connectionGeneration = connectionGenerations[sessionID]

        defer {
            if !joinSucceeded, let pid = playerID {
                membershipCoordinator.removeJoinedPlayer(sessionID: sessionID)
                logger.warning("Rolled back join state for session \(sessionID.rawValue), player \(pid.rawValue)")
            }
        }

        do {
            if let joinResult = try await performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: jwtAuthInfo
            ) {
                playerID = joinResult.playerID
                joinSucceeded = true
                await completeJoinSuccess(
                    requestID: requestID,
                    sessionID: sessionID,
                    playerSession: playerSession,
                    joinResult: joinResult
                )
            } else {
                logger.warning("Join denied for session \(sessionID.rawValue)")
                await sendJoinError(
                    requestID: requestID,
                    sessionID: sessionID,
                    code: .joinDenied,
                    message: "Join denied"
                )
            }
        } catch {
            logger.error("Join failed for session \(sessionID.rawValue): \(error)")
            let (errorCode, errorMessage) = AdapterErrorMapping.mapJoinFailure(error)
            if case .superseded? = error as? JoinError {
                // A newer join of the player replaced this one: the error is the session's last
                // frame, with the 4017 close behind it, as the router answers it (#861, #947), so
                // the client doesn't rejoin into a kick loop.
                if let errorData = joinErrorData(requestID: requestID, code: errorCode, message: errorMessage) {
                    sendFinalFrameAndClose(errorData, kind: messageEncoder.encoding.frameKind, to: sessionID, generation: connectionGeneration, close: .superseded)
                } else {
                    closeSessionDetached(sessionID, generation: connectionGeneration, with: .superseded)
                }
                return
            }
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: errorCode,
                message: errorMessage
            )
        }
    }

    private func completeJoinSuccess(
        requestID: String,
        sessionID: SessionID,
        playerSession: PlayerSession,
        joinResult: JoinResult
    ) async {
        _ = await withInitialSync(for: joinResult.playerID, sessionID: joinResult.sessionID) { ticket in
            await sendJoinResponse(
                requestID: requestID,
                sessionID: sessionID,
                success: true,
                playerID: joinResult.playerID.rawValue,
                playerSlot: joinResult.playerSlot
            )
            await _syncStateForNewPlayer(playerID: joinResult.playerID, sessionID: joinResult.sessionID, ticket: ticket)
        }

        logger.info("Client joined: session=\(sessionID.rawValue), player=\(joinResult.playerID.rawValue), playerID=\(playerSession.playerID)")
    }

    // MARK: - State Query Methods

    /// Check if a session is connected (but may not have joined)
    func _isConnectedImpl(sessionID: SessionID) -> Bool {
        membershipCoordinator.hasClient(sessionID: sessionID)
    }

    /// Check if a session has joined
    func _isJoinedImpl(sessionID: SessionID) -> Bool {
        membershipCoordinator.hasPlayer(sessionID: sessionID)
    }

    /// Get the playerID for a session (if joined)
    func _getPlayerIDImpl(for sessionID: SessionID) -> PlayerID? {
        membershipCoordinator.playerID(for: sessionID)
    }

    /// Get all sessions for a playerID
    func _getSessionsImpl(for playerID: PlayerID) -> [SessionID] {
        membershipCoordinator.sessionIDs(for: playerID)
    }

    /// Send join error to client using unified error format
    private func sendJoinError(
        requestID: String,
        sessionID: SessionID,
        code: ErrorCode,
        message: String,
        details: [String: AnyCodable]? = nil
    ) async {
        do {
            let errorData = try encodeJoinError(requestID: requestID, code: code, message: message, details: details)
            enqueueOutbound(errorData, to: sessionID, kind: messageEncoder.encoding.frameKind)

            if logger.logLevel <= .debug {
                logger.debug("📤 Sent join error", metadata: [
                    "requestID": "\(requestID)",
                    "sessionID": "\(sessionID.rawValue)",
                    "code": "\(code.rawValue)"
                ])
            }
        } catch {
            logger.error("❌ Failed to send join error", metadata: [
                "requestID": .string(requestID),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
    }

    /// A join error frame in the adapter's encoding: `requestID` and `landID` in its details.
    private func encodeJoinError(
        requestID: String,
        code: ErrorCode,
        message: String,
        details: [String: AnyCodable]? = nil
    ) throws -> Data {
        var errorDetails = details ?? [:]
        errorDetails["requestID"] = AnyCodable(requestID)
        errorDetails["landID"] = AnyCodable(landID)
        let errorPayload = ErrorPayload(code: code, message: message, details: errorDetails)
        return try messageEncoder.encode(TransportMessage.error(errorPayload))
    }

    /// `encodeJoinError`, or `nil` (logged) when it doesn't encode.
    private func joinErrorData(requestID: String, code: ErrorCode, message: String) -> Data? {
        do {
            return try encodeJoinError(requestID: requestID, code: code, message: message)
        } catch {
            logger.error("❌ Failed to encode join error", metadata: [
                "requestID": .string(requestID),
                "error": .string("\(error)")
            ])
            return nil
        }
    }

    /// Send join response to client
    private func sendJoinResponse(
        requestID: String,
        sessionID: SessionID,
        success: Bool,
        playerID: String? = nil,
        playerSlot: Int32? = nil,
        reason: String? = nil
    ) async {
        do {
            // Include encoding in join response so client knows which format to use
            let encoding = messageEncoder.encoding.rawValue
            let response = TransportMessage.joinResponse(
                requestID: requestID,
                success: success,
                playerID: playerID,
                playerSlot: playerSlot,
                encoding: encoding,
                reason: reason,
                stateUpdateFeatures: success && !stateUpdateFeatures.isEmpty ? stateUpdateFeatures : nil
            )
            let responseData = try messageEncoder.encode(response)
            enqueueOutbound(responseData, to: sessionID, kind: messageEncoder.encoding.frameKind)

            if logger.logLevel <= .debug {
                logger.debug("📤 Sent join response", metadata: [
                    "requestID": "\(requestID)",
                    "sessionID": "\(sessionID.rawValue)",
                    "success": "\(success)",
                    "playerID": "\(playerID ?? "nil")",
                    "playerSlot": "\(playerSlot.map { String($0) } ?? "nil")"
                ])
            }
        } catch {
            logger.error("❌ Failed to send join response", metadata: [
                "requestID": "\(requestID)",
                "sessionID": "\(sessionID.rawValue)",
                "error": "\(error)"
            ])
        }
    }
}

// MARK: - Debug Freeze

/// Debug freeze and projection, used by E2E state convergence checks.
///
/// A freeze pauses the land (no tick or sync body starts, tickless inputs are held), waits for
/// in-flight work to finish, then settles in one sync-only keeper turn (#546 L2d-1). The projection is
/// computed from the state copy the settle synced, so every client that applied the settle
/// frames can be compared with it. While frozen, requested syncs are deferred to resume.
///
/// Each freeze has a generation and a token. Further freezes while frozen add references to it;
/// `debugResume(freezeToken:)` drops one, and a token of an older generation is a no-op. The
/// freeze is released when the last reference is dropped, when the drain and settle miss their
/// deadline, or by the auto-resume timer; release never waits for an unfinished settle.
extension TransportAdapter {
    /// Freeze the land and run the settle cycle; while already frozen, add a reference and return
    /// the existing token without a new settle. Each call restarts the auto-resume timer.
    ///
    /// - Throws: `DebugFreezeError.settleTimedOut` when drain and settle miss their deadline (the
    ///   freeze is released), `DebugFreezeError.released` when the freeze was released (e.g. by
    ///   auto-resume) before its settle finished. A land that failed throws its `LandFailure`
    ///   (also when the settle's own plan fails, which ends the land in the settle's turn), and
    ///   one that is closing throws `LandInputRejection.landClosed`.
    public func debugFreeze() async throws -> DebugFreezeResponse {
        if debugFreezeState.count == 0 {
            debugFreezeState.generation &+= 1
            debugFreezeState.token = UUID().uuidString
            debugFreezeState.settled = nil
            let generation = debugFreezeState.generation
            let ticket = debugFreezeTickets.issue(.freeze)
            debugFreezeState.settleTask = Task { try await self.debugSettle(generation: generation, ticket: ticket) }
        }
        debugFreezeState.count += 1
        let reused = debugFreezeState.count > 1
        let generation = debugFreezeState.generation
        let token = debugFreezeState.token
        debugRestartAutoResumeTimer()

        guard let settleTask = debugFreezeState.settleTask else {
            throw DebugFreezeError.released
        }
        let settled: DebugFreezeState<State>.Settled
        do {
            // The settle published its result itself, while its ticket was current.
            settled = try await settleTask.value
        } catch {
            // Drop this caller's reference, only if its freeze is still the current one.
            if debugFreezeState.generation == generation, debugFreezeState.count > 0 {
                debugFreezeState.count -= 1
                if debugFreezeState.count == 0 {
                    await debugReleaseFreeze()
                }
            }
            throw error
        }
        // Released (and maybe frozen again) while settling: this result describes nothing.
        guard debugFreezeState.generation == generation, debugFreezeState.count > 0 else {
            throw DebugFreezeError.released
        }
        return DebugFreezeResponse(
            freezeToken: token,
            tickId: settled.tickId,
            freezeCount: debugFreezeState.count,
            reused: reused
        )
    }

    /// Projection of the settle copy for `playerID` (broadcast plus that player's view), or the
    /// broadcast-only projection when `playerID` is nil. Side-effect free: uses a fresh
    /// `SyncEngine`, so the adapter's diff caches are untouched.
    public func debugProjection(playerID: PlayerID?) throws -> DebugProjectionResponse {
        guard debugFreezeState.count > 0, let settled = debugFreezeState.settled else {
            throw DebugFreezeError.notFrozen
        }
        let engine = SyncEngine(for: State.self)
        let snapshot: StateSnapshot
        if let playerID {
            snapshot = try engine.snapshot(for: playerID, from: settled.state, mode: .all)
        } else {
            snapshot = try engine.extractBroadcastSnapshot(from: settled.state, mode: .all)
        }
        return DebugProjectionResponse(
            freezeToken: debugFreezeState.token,
            tickId: settled.tickId,
            playerID: playerID?.rawValue,
            membershipChanged: membershipCoordinator.membershipEpoch != settled.membershipEpoch,
            state: snapshot.values
        )
    }

    /// Drop one reference of the freeze identified by `freezeToken`. A token of a freeze that was
    /// already released (e.g. by auto-resume) is a no-op, so it cannot release a newer freeze.
    /// Releasing the last reference resumes the land and runs the syncs deferred while frozen.
    public func debugResume(freezeToken: String) async -> DebugResumeResponse {
        guard debugFreezeState.count > 0, freezeToken == debugFreezeState.token else {
            return DebugResumeResponse(freezeCount: debugFreezeState.count, resumed: false)
        }
        debugFreezeState.count -= 1
        guard debugFreezeState.count == 0 else {
            return DebugResumeResponse(freezeCount: debugFreezeState.count, resumed: false)
        }
        await debugReleaseFreeze()
        return DebugResumeResponse(freezeCount: 0, resumed: true)
    }

    /// Whether at least one freeze reference is held.
    public func isDebugFrozen() -> Bool {
        debugFreezeState.count > 0
    }

    /// Override the auto-resume timeout (default from `DEBUG_FREEZE_TIMEOUT_SECONDS`).
    /// Takes effect at the next freeze call.
    public func setDebugFreezeAutoResumeTimeout(_ timeout: Duration) {
        debugFreezeState.autoResumeTimeout = timeout
    }

    /// Override the drain + settle deadline (default 10 s). Takes effect at the next freeze.
    public func setDebugFreezeSettleDeadline(_ deadline: Duration) {
        debugFreezeState.settleDeadline = deadline
    }

    /// While frozen, record the request and return true so the caller skips this sync.
    func debugDeferSyncIfFrozen() -> Bool {
        guard debugFreezeState.count > 0 else { return false }
        debugFreezeState.deferredSyncNow = true
        return true
    }

    private func debugIsCurrent(_ generation: UInt64) -> Bool {
        debugFreezeState.generation == generation && debugFreezeState.count > 0
    }

    /// Pause and drain the keeper, then settle (#546 L2d-1, plan §3.8.3): wait for the writer,
    /// then the keeper's settle turn (`LandKeeper.settleTurn`), which checks the fence and runs
    /// the settle phase (`runSettlePhaseInTurn`), then publish. One deadline covers the drain,
    /// the writer wait and the wait for the turn (the turn checks it when it starts, not while
    /// it runs). `ticket` is this freeze's: every check after an await, and the publish, act only
    /// while it is current.
    private func debugSettle(
        generation: UInt64,
        ticket: Ticket<DebugFreezeKey>
    ) async throws -> DebugFreezeState<State>.Settled {
        let deadline = ContinuousClock.now + debugFreezeState.settleDeadline
        let drained = await keeper.debugFreeze(generation: generation, timeout: debugFreezeState.settleDeadline)
        guard debugFreezeTickets.isCurrent(ticket) else { throw DebugFreezeError.released }
        guard drained else { throw DebugFreezeError.settleTimedOut }
        let fence = LandKeeper<State>.SettleFence(generation: generation, deadline: deadline)
        var found: DebugFreezeState<State>.Settled?
        while found == nil {
            // Wait until earlier phases' frames left the writer, so the settle frames are not
            // queued behind them. Not skipped for back-pressure, and bounded by the deadline.
            if hasPendingStateElement {
                let writerDrained = await waitForSyncCycleDrain(before: deadline)
                guard debugFreezeTickets.isCurrent(ticket) else { throw DebugFreezeError.released }
                guard writerDrained else { throw DebugFreezeError.settleTimedOut }
            }
            await holds.at(.settleBeforeCommit)
            let outcome = await keeper.settleTurn(via: self, fence: fence)
            switch outcome {
            case let .settled(state, tickId, membershipEpoch, _):
                found = DebugFreezeState<State>.Settled(state: state, tickId: tickId, membershipEpoch: membershipEpoch)
            case let .failed(failure):
                // The land ended in the settle's turn.
                throw failure
            case .timedOut:
                throw DebugFreezeError.settleTimedOut
            case .released, .refused(.notCurrent):
                throw DebugFreezeError.released
            case let .closed(failure):
                // A failed land names its failure; a draining one is closed.
                throw failure ?? LandInputRejection.landClosed
            case .refused(.outputClosed):
                throw outputGate.failure ?? LandInputRejection.landClosed
            case .refused(.writerBusy):
                // A sync cycle's element entered the writer since the wait: wait again.
                guard debugFreezeTickets.isCurrent(ticket) else { throw DebugFreezeError.released }
            }
        }
        guard let settled = found else { preconditionFailure("the settle loop ends only with a result") }
        await holds.at(.settleBeforePublish)
        // Checked after the last await, in the publish's segment, so a release meanwhile is
        // never published and an older settle never writes over a newer freeze's state.
        let published = debugFreezeTickets.ifCurrent(ticket) { _ -> Result<DebugFreezeState<State>.Settled, any Error> in
            // A land that failed or closed since the settle's turn has ended: name the cause
            // instead of publishing a success for it (#730). All three reads are nonisolated.
            if let failure = keeper.failure ?? outputGate.failure { return .failure(failure) }
            if keeper.isDraining { return .failure(LandInputRejection.landClosed) }
            if debugFreezeKeepsEventsUnsent { debugFreezeState.deferredSyncNow = true }
            debugFreezeState.settled = settled
            return .success(settled)
        }
        guard let published else { throw DebugFreezeError.released }
        return try published.get()
    }

    /// Waits until the writer holds no sync cycle element; `false` when `deadline` passed first.
    /// The deadline's timer cancels the wait, so no wait is left behind.
    private func waitForSyncCycleDrain(before deadline: ContinuousClock.Instant) async -> Bool {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return false }
        let writer = outboundWriter
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await writer.waitForSyncCycleDrain()
                return !Task.isCancelled
            }
            group.addTask {
                try? await safeTaskSleep(for: remaining)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The settle phase, in the keeper's settle turn (`LandKeeper.settleTurn`), on the shared
    /// executor: no frozen defer, no back-pressure deferral and no joiners, so no other phase
    /// changes how it runs. Refuses when `settle` isn't the current freeze, the output is
    /// closed, or a sync cycle's element entered the writer since the settle's wait. The
    /// membership epoch is read in the plan's segment (a join or leave from here on is not in
    /// the copy and shows up as `membershipChanged`). An empty land plans nothing and keeps its
    /// dirty flags. A plan's first throw ends the land (#535): the keeper ends it in the turn.
    func runSettlePhaseInTurnIsolated<S: StateNodeProtocol>(
        state: S,
        settle: InTurnSettle,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        // Checked in release builds too: a draft left here would be sent as the settle's.
        precondition(inTurnSyncStreamDrafts.isEmpty, "sync-stream drafts left from an earlier phase")
        let commit = runSettlePhase(state: state, settle: settle, recording: recording)
        let drafts = inTurnSyncStreamDrafts
        inTurnSyncStreamDrafts = []
        let result: InTurnSyncResult
        switch commit {
        case let .committed(_, clearDirtyFlags): result = .committed(clearDirtyFlags: clearDirtyFlags)
        case .empty, .refused: result = .skipped
        case let .failed(failure): result = .landFailed(failure)
        }
        return InTurnSyncOutput(result, syncStream: drafts, settle: commit)
    }

    private func runSettlePhase<S: StateNodeProtocol>(
        state: S,
        settle: InTurnSettle,
        recording: InTurnSyncRecording?
    ) -> InTurnSettleCommit {
        guard debugIsCurrent(settle.generation) else { return .refused(.notCurrent) }
        guard !outputGate.isClosed, !outboundWriter.isFinished else { return .refused(.outputClosed) }
        guard !hasPendingStateElement else { return .refused(.writerBusy) }
        let membershipEpoch = membershipCoordinator.membershipEpoch
        guard !membershipCoordinator.isEmpty else { return .empty(membershipEpoch: membershipEpoch) }
        guard let state = state as? State else {
            preconditionFailure("runSettlePhaseInTurn called with a state of another land type")
        }
        // Read once, as the ordinary phase does.
        let clearDirtyFlags = enableDirtyTracking
        do {
            let read = recording.map { SyncOutputRead(turnKind: $0.turnKind, position: $0.position) }
            try runFullSyncPhase(state: state, read: read)
        } catch {
            logger.error("Debug freeze settle sync failed: the land ends", metadata: [
                "error": .string("\(error)")
            ])
            return .failed(error as? LandFailure ?? LandFailure(
                kind: .syncPlan,
                detail: String(describing: error),
                position: LandFailurePosition(stage: .syncPhase)
            ))
        }
        return .committed(membershipEpoch: membershipEpoch, clearDirtyFlags: clearDirtyFlags)
    }

    /// Events still queued (kept by the settle's phase, or queued since) that only the resume
    /// delivers: on a land without periodic sync nothing else sends them, and syncs are frozen.
    /// Read in the publish's segment and in the release's, so whichever runs sees them.
    private var debugFreezeKeepsEventsUnsent: Bool {
        pendingEventManager.hasAnyEvents && !keeper.hasPeriodicSync
    }

    /// Release the current freeze generation. Does not wait for an unfinished settle: it cancels
    /// it, so a settle waiting for the writer or between retries ends at once instead of at its
    /// deadline. After the ticket ends, so every check after its await sees the release and
    /// throws `released`. It publishes nothing, and the keeper refuses to freeze a released
    /// generation again.
    private func debugReleaseFreeze() async {
        let generation = debugFreezeState.generation
        debugFreezeTickets.end(.freeze)
        debugFreezeState.count = 0
        debugFreezeState.autoResumeTask?.cancel()
        debugFreezeState.autoResumeTask = nil
        debugFreezeState.autoResumeGeneration &+= 1
        debugFreezeState.settleTask?.cancel()
        debugFreezeState.settleTask = nil
        debugFreezeState.settled = nil
        // Also checked here: a release before the settle's publish ends its ticket, so the
        // publish never records the events the settle kept (#730).
        let runSyncNow = debugFreezeState.deferredSyncNow || debugFreezeKeepsEventsUnsent
        debugFreezeState.deferredSyncNow = false

        await keeper.debugResume(generation: generation)

        // Frozen again meanwhile: that freeze defers syncs itself; keep these for its resume.
        guard debugFreezeState.count == 0 else {
            debugFreezeState.deferredSyncNow = debugFreezeState.deferredSyncNow || runSyncNow
            return
        }
        await debugResumeInTurn(runDeferredSync: runSyncNow)
    }

    /// The resume (#546 L2b, plan §3.4): step 1, the deferred sync as one outside request,
    /// awaited (a full phase also covers broadcast-only changes); step 2, the join-sync
    /// request, which branches on step 1's outcome.
    private func debugResumeInTurn(runDeferredSync: Bool) async {
        var deferredSync: InTurnSyncResult?
        if runDeferredSync {
            deferredSync = await keeper.syncTurnNow(via: self, reason: .resume)
        }
        await holds.at(.resumeAfterSync)
        // Frozen again across step 1: that freeze's resume requests the joins' turn. (A step 1
        // that met the new freeze was skipped, and its phase deferred its sync again.)
        guard debugFreezeState.count == 0 else { return }
        switch deferredSync {
        case .deferredBackPressure:
            // The writer still holds an earlier phase: the writer-drain retry (no periodic
            // sync) or the next periodic phase delivers the deferred work and flips the ready
            // joins. A second phase now would only defer again.
            return
        case .failed, .landFailed:
            // The land ends; nothing more to flip.
            return
        case nil, .committed, .skipped, .notRequested, .unsupported:
            break
        }
        // Step 1 ran without joiners past the budget, or didn't run: a tickless land's join that
        // became ready during the freeze (its sync-only turn was skipped) needs its own turn (#69).
        if hasJoinsAwaitingSyncIsolated() {
            await keeper.requestJoinSyncTurn()
        }
    }

    private func debugRestartAutoResumeTimer() {
        debugFreezeState.autoResumeTask?.cancel()
        debugFreezeState.autoResumeGeneration &+= 1
        let timerGeneration = debugFreezeState.autoResumeGeneration
        let timeout = debugFreezeState.autoResumeTimeout
        debugFreezeState.autoResumeTask = Task { [weak self] in
            do {
                try await safeTaskSleep(for: timeout)
            } catch {
                return
            }
            await self?.debugAutoResume(timerGeneration: timerGeneration)
        }
    }

    private func debugAutoResume(timerGeneration: UInt64) async {
        await holds.at(.debugFreezeAutoResumeFired)
        guard debugFreezeState.count > 0,
              debugFreezeState.autoResumeGeneration == timerGeneration else {
            await holds.at(.debugFreezeAutoResumeStale)
            return
        }
        logger.warning("Debug freeze auto-resumed after timeout", metadata: [
            "landID": .string(landID),
            "freezeCount": .stringConvertible(debugFreezeState.count),
        ])
        await debugReleaseFreeze()
    }
}

/// Tests: resumes a continuation once, from whichever comes first. A `resume()` before
/// `install` resumes the continuation as soon as it is installed.
private final class TestingResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
