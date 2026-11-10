import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack
import Logging

private enum HexEncoding {
    /// Hex-encode bytes as lowercase, optionally separated.
    ///
    /// This intentionally avoids `String(format:)` (C varargs) to keep formatting type-safe.
    static func lowercaseHexString(_ data: Data, separator: String = " ") -> String {
        guard !data.isEmpty else { return "" }
        let digits: [UInt8] = Array("0123456789abcdef".utf8)

        var out = String()
        // Rough estimate: 2 chars per byte + separators.
        out.reserveCapacity(data.count * 3)

        for (i, byte) in data.enumerated() {
            if i > 0 {
                out.append(separator)
            }
            out.unicodeScalars.append(UnicodeScalar(UInt32(digits[Int(byte >> 4)]))!)
            out.unicodeScalars.append(UnicodeScalar(UInt32(digits[Int(byte & 0x0F)]))!)
        }

        return out
    }
}

// MARK: - Sync phase types

/// The prefix of each pending event queue that one sync phase read. Its commit removes exactly
/// this prefix; events queued later stay for the next cycle. A plan reads the queue once, and
/// every frame it builds covers exactly `[0, count)`. A plan that throws commits nothing, so the
/// queue is unchanged.
struct SyncPhaseConsumedEvents: Sendable, Equatable {
    var targeted = 0
    var broadcast = 0
}

/// A plan's sync-lag classification (#332): written to the lag state by the plan's commit, so a
/// plan that doesn't commit changes nothing.
struct SyncLagPlanned: Sendable {
    /// Sessions whose frames this plan withholds because they are pending, newly or still.
    var markPending: [SessionID] = []
    /// Sessions this plan resyncs: true for the lagging one (counted), false for another session
    /// of the same player, which gets the snapshot too.
    var resyncs: [SessionID: Bool] = [:]
    /// Terminal closes the classification found due.
    var closes: [(sessionID: SessionID, code: UInt16)] = []
    /// The players whose full view this plan types as a resync.
    var resyncPlayers: Set<PlayerID> = []
    /// Resync players whose snapshot didn't encode whole: no snapshot was sent, and their
    /// sessions stay as they were.
    var failedSnapshots: Set<PlayerID> = []
    /// A resync was due but this plan isn't a full one: the next cycle runs full.
    var wantsFullPlan = false
    /// The session whose join firstSync this plan is (`planFirstSync`): tracking starts at it.
    var firstSyncSession: SessionID?
    /// This plan's resyncs made it reset the broadcast key scope (#90), and that frame's bytes
    /// over all recipients.
    var causedKeyScopeReset = false
    var keyScopeResetBytes = 0
    /// Events this plan consumes for sessions it withholds: dropped, counted at commit.
    var droppedEvents = 0
}

/// One frame of a sync phase, addressed to one session of this land.
struct SyncPhaseFrame: Sendable {
    let data: Data
    let sessionID: SessionID
    /// A state-update frame (it carries the plan's sync sequence, #332); not an event frame or a
    /// JoinResponse.
    var isStateUpdate = false
    /// A resync's snapshot (#332): sent ahead of the session's other frames of the plan.
    var isResyncSnapshot = false
    /// Row addressing, merged frames: an unsynced recipient's full view, which holds the committed
    /// tables and is sent ahead of the shared frame that brings them to live.
    var isFullViewBeforeSharedFrame = false
}

/// A row of a slot-addressed table, as a patch at or below it names it.
struct SyncRowRef: Hashable, Sendable {
    /// The root field's path (`/monsters`).
    let rootPath: String
    /// The row's path (`/monsters/a`).
    let rowPath: String
    let slot: Int32

    /// The row `patch` lies at or below, when its split carries one.
    init?(_ patch: StatePatch) {
        guard let slot = patch.split?.row?.slot else { return nil }
        let utf8 = patch.path.utf8
        guard utf8.first == UInt8(ascii: "/") else { return nil }
        let afterRoot = utf8.index(after: utf8.startIndex)
        guard let rootEnd = utf8[afterRoot...].firstIndex(of: UInt8(ascii: "/")) else { return nil }
        let afterKey = utf8.index(after: rootEnd)
        let rowEnd = utf8[afterKey...].firstIndex(of: UInt8(ascii: "/")) ?? utf8.endIndex
        self.rootPath = String(patch.path[..<rootEnd])
        self.rowPath = String(patch.path[..<rowEnd])
        self.slot = slot
    }

    /// Whether `path` is the row's or lies below it, on component boundaries: `/rows/a` covers
    /// `/rows/a/hp`, not `/rows/ab`.
    func covers(_ path: String) -> Bool {
        guard path.hasPrefix(rowPath) else { return false }
        let rest = path.utf8.dropFirst(rowPath.utf8.count)
        return rest.isEmpty || rest.first == UInt8(ascii: "/")
    }
}

/// A standalone firstSync plan on a land with row addressing in effect (a programming error).
struct StandaloneFirstSyncRefused: Error {}

/// A session that receives this cycle's frames: joined and not in initial sync (#69).
struct SyncPhaseRecipient: Sendable {
    let sessionID: SessionID
    let playerID: PlayerID
}

/// A ready in-turn join flipped by a full sync phase (#69): its firstSync is planned from the
/// turn's end state with the others' diffs, and its frames follow theirs.
struct SyncPhaseJoiner: Sendable {
    let recipient: SyncPhaseRecipient
    let ticket: Ticket<SessionID>
    let joinResponse: Data
}

/// A state update that failed to encode (`TransportAdapter.encodeUpdatesSerially`).
struct SyncPhaseEncodeFailure: Sendable {
    let sessionID: SessionID
    let playerID: PlayerID
    let message: String
}

/// The failure `TransportAdapter.syncEncodeFaultForTesting` injects.
struct SyncPhaseInjectedEncodeFault: Error {}

extension StateUpdate {
    /// The patches a re-encode after an encode failure tries one by one (none for `.noChange`).
    var patchesForDroppingEncode: [StatePatch] {
        switch self {
        case .noChange: return []
        case .diff(let patches), .firstSync(let patches): return patches
        }
    }
}

/// Input of the change-object metrics, applied by the commit.
struct SyncPhaseMetrics {
    let updates: [StateUpdate]
    let broadcastSnapshot: StateSnapshot
}

/// The broadcast-only cycle's log line, written by the commit.
struct SyncPhaseBroadcastLog {
    let patchCount: Int
    let bytes: Int?
    let mode: SnapshotMode
}

/// Everything one sync phase sends and consumes.
///
/// The sync phase of a room turn has two synchronous steps, run in the same actor turn:
/// - **plan** (`planSyncPhase`, `planBroadcastOnlySyncPhase`, `planFirstSync`): reads the state
///   copy, the recipients and the event queue, passed as parameters; computes the diffs, staging
///   the cache updates in `staged` instead of writing them; encodes every frame. It changes
///   nothing else, except the encoders' dynamic key tables (see `keyScopeResetPending`). It also reads the adapter's
///   configuration (encoding, dirty-tracking settings) and membership details (player slots,
///   membership stamps) directly; that is synchronous and fine until the sync phase runs inside
///   the keeper's turn.
/// - **commit** (`commitSyncPhase`): writes the staged caches and firstSync marks, removes the
///   consumed events, applies the metric and dirty-tracking updates, and enqueues the frames as
///   one writer element.
///
/// Neither an encode failure nor an extraction failure fails a plan: the update is re-encoded
/// without the patches that do not encode, and a field whose snapshot conversion throws is left
/// out (`droppedUpdates`). A plan that still throws (only the test fault hook does) commits
/// nothing: caches, firstSync marks, events and metrics are unchanged. Its dirty fields are merged
/// into the next plan's (`TransportAdapter.carriedDirtyFields`), and the next committed full plan
/// resets the key scopes (`TransportAdapter.keyScopeResetPending`).
/// One sync plan's phase times: snapshot extraction (broadcast and per-player in one call), the
/// broadcast diff, and the per-player diffs. Encoding is in none of them. `combined`: no merged
/// broadcast frames, so the per-player time includes folding the broadcast diff in.
struct SyncPhaseTimes: Equatable, Sendable {
    var extract: Duration
    var broadcast: Duration
    var perPlayer: Duration
    var combined: Bool
}

struct SyncPhasePlan {
    /// The land's sync sequence every state-update frame of this plan carries (#332); nil with
    /// lag tracking off.
    var syncSeq: UInt64?
    /// What this plan's lag classification decided (#332), applied by its commit.
    var syncLag = SyncLagPlanned()
    /// Frames in issue order. Per session: merged broadcast frame, targeted event frames,
    /// per-player state frame.
    var frames: [SyncPhaseFrame] = []
    /// State update frames among `frames` (profiling counter).
    var stateUpdateCount = 0
    var consumedEvents = SyncPhaseConsumedEvents()
    /// A full cycle's plan (`syncNow`): its commit ends the carry of failed plans' dirty fields.
    var isFullCycle = false
    /// The plan typed every recipient's update `.firstSync` (key scopes reset): its commit ends a
    /// pending key scope reset.
    var resetsKeyScopes = false
    /// A frame the plan encoded for was not produced (not even an empty update encoded), so the
    /// encoders' key tables may hold slots no client learned: the next full plan resets them.
    /// A nil per-player frame also drops that player's staged per-player cache and mark, and a nil
    /// opcode 107 merged frame the staged broadcast cache. A nil combined or broadcast-only
    /// separate frame leaves the shared broadcast cache advanced for every other player, so that
    /// player misses those broadcast changes until they change again, as before plan + commit.
    var leavesKeyTablesAhead = false
    /// Cache updates and firstSync marks; the commit writes them to the sync engine.
    var staged = SyncEngine.StagedCaches()
    /// The typed tables' writes to last-sent (the broadcast diff on the tables); the commit
    /// applies them. Stands for `staged.broadcast`, which stays nil then.
    var stagedTables = SyncTableStaged()
    /// Phase times of a full plan, only with transport profiling on.
    var phaseTimes: SyncPhaseTimes?
    /// Patches (or whole updates) dropped because they did not encode.
    var droppedUpdates = 0
    /// The first encode or extraction failure's message (for the dropped-updates log).
    var dropReason: String?
    /// A joiner's firstSync did not encode even empty: nothing is committed for it, so it stays
    /// unmarked and the next full cycle gives it its whole view (`planFullViewUpdate`).
    var skippedJoiner = false
    /// A player's firstSync was committed outside a broadcast key scope reset (#90): its client's
    /// broadcast key map is empty, while the shared broadcast key table still holds every slot
    /// defined before the join, so later merged broadcast frames would reference slots it never
    /// learned. The commit requests a key scope reset: the next plan with recipients types its
    /// merged broadcast frame `.firstSync`, and every client and the encoder define again.
    var needsBroadcastKeyReset = false
    /// The plan encoded a merged broadcast frame with state patches: the shared broadcast key
    /// table may hold slots from here on (`broadcastKeysMayBeDefined`).
    var encodesBroadcastPatches = false
    /// In-turn joins this plan flips (#69): the commit ends their joining and resumes their
    /// waiters. Their frames (JoinResponse, then firstSync) are in `frames`.
    var flips: [(sessionID: SessionID, ticket: Ticket<SessionID>)] = []
    /// Opcode 107: the event frames this plan's consumed targeted events hold for each joining
    /// session (#69), read by a full plan to decide the held-event bound before it picks its
    /// flips; the commit appends them. `heldEventsEnd` is the targeted count they were read to;
    /// the commit reads them again if the plan consumed a different count.
    var heldEvents: [SessionID: [Data]]?
    var heldEventsEnd = 0
    /// In-turn joiners whose firstSync did not encode, not even empty: not flipped (#69).
    var encodeSkippedJoiners: [SessionID] = []
    /// Change-object metric input; `nil` when metrics are not collected.
    var metrics: SyncPhaseMetrics?
    /// The commit counts this sync toward the metrics sampling (`AUTO_DIRTY_SAMPLE_EVERY`).
    var countsChangeMetricsSync = false
    var broadcastOnlyLog: SyncPhaseBroadcastLog?
    /// What the plan intends to send, per scope, for the sync stream; nil unless the land records
    /// it (`TransportAdapter.digestsPlans`).
    var digest: SyncOutputDigestInput?
    /// Row addressing: the rows this plan dropped because a value of theirs did not encode
    /// (`SyncRowRef`). None of their patches is sent and none of their writes is committed.
    var droppedRows: Set<SyncRowRef> = []
    /// Row addressing: the root fields the next plans diff again because a row was dropped
    /// (`TransportAdapter.rowRetryFields`), as this plan's commit leaves them; nil: unchanged.
    var rowRetryFields: Set<String>?

    /// Counts the fields an extraction dropped.
    mutating func noteExtractionDrops(_ drops: ExtractionDrops) {
        guard drops.count > 0 else { return }
        droppedUpdates += drops.count
        dropReason = dropReason ?? drops.firstError
    }
}

/// One plan's scopes for the sync stream (record format 2.1): the patches it intends to send
/// before encoding, the fields its extraction dropped, and the scopes whose encoding dropped
/// patches. The commit hashes it in its own synchronous segment.
struct SyncOutputDigestInput {
    /// The broadcast diff; nil when the plan has no broadcast scope.
    var broadcastPatches: [StatePatch]?
    /// Each recipient player's update patches (in combined encodings, broadcast included).
    var perPlayerPatches: [PlayerID: [StatePatch]] = [:]
    /// Top-level fields the extraction dropped: "broadcast" or a player ID.
    var extractionDrops: [String: [String]] = [:]
    /// Scopes ("broadcast" or a player ID) whose encoding dropped patches: unverifiable.
    var encodeDropScopes: Set<String> = []
    /// Players whose whole view this plan sends (a firstSync, or a full view after a failed
    /// one). Each gets a seed marker instead of a per-player scope in the output; a view that
    /// was not sent at all has no entry.
    var seeds: [PlayerID: SeedDigest] = [:]
    /// Players this plan resyncs in place (#332). Their seeds follow a clear in the stream, as
    /// a reconnect's do: the verifier drops the view it had for them before the output.
    var resyncPlayers: Set<PlayerID> = []
    /// Opcode 107: the events the plan consumed, in emit order; nil in the other encodings or
    /// when one of them has no canonical form.
    var events: [CanonicalSyncEvent]?
    /// Opcode 107: the largest keeper sequence among the consumed events that have one.
    var eventsThroughSequence: Int64?
    /// A full plan: it commits the per-player scope of its recipients (`recipients`). False for
    /// a broadcast-only cycle and a firstSync.
    var commitsPerPlayer = false
    /// The plan reset its recipients' key scopes (`keyScopeResetPending`).
    var resetsKeyScopes = false
    /// A full plan's recipients that have a committed firstSync (not those it sends a full view).
    var recipients: [PlayerID] = []
    /// Recipients whose planned update was not sent at all: their per-player cache was not
    /// committed.
    var uncommitted: Set<PlayerID> = []
    /// A firstSync plan: it records seed markers only, no output.
    var isFirstSync = false

    static let broadcastScope = "broadcast"
    /// The events scope in `encodeDropScopes`: a consumed event without a canonical form.
    static let eventsScope = "events"

    /// A seed's planned view, and what was dropped from the view the client got.
    struct SeedDigest {
        var patches: [StatePatch]
        var drops: Set<ReevaluationRecordedSyncMarker.ViewDrop> = []
        /// The fields whose extraction was dropped from the view (`viewDropFields`).
        var dropFields: [String] = []
    }

    /// A player's encode dropped patches: its scope is unverifiable. With a frame (`committed`)
    /// its seed, if any, was degraded; with none, its per-player cache and firstSync mark were
    /// not committed and nothing reached the client, so it leaves the output and has no seed.
    mutating func noteEncodeDrop(playerID: PlayerID, committed: Bool) {
        encodeDropScopes.insert(playerID.rawValue)
        if committed {
            seeds[playerID]?.drops.insert(.encode)
        } else {
            perPlayerPatches.removeValue(forKey: playerID)
            if seeds.removeValue(forKey: playerID) == nil {
                uncommitted.insert(playerID)
            }
        }
    }

    mutating func noteDrops(_ drops: ExtractionDrops) {
        if !drops.broadcastFields.isEmpty {
            extractionDrops["broadcast", default: []].append(contentsOf: drops.broadcastFields.sorted())
        }
        for (player, fields) in drops.perPlayerFields where !fields.isEmpty {
            extractionDrops[player.rawValue, default: []].append(contentsOf: fields.sorted())
        }
    }
}

/// Where the plan about to run read its state, for the sync output it records.
struct SyncOutputRead {
    let turnKind: ReevaluationRecordedSyncOutput.TurnKind
    /// Nil when the read cannot be located.
    let position: SyncReadPosition?
}

/// Where a `TransportAdapter` awaits its test hold hook (`installHolds`).
enum TransportAdapterHoldPoint: Hashable, Sendable {
    /// An in-turn join (#69) after its admission and before `registerSession`: admitted, its
    /// OnJoin may be consumed, but it can't flip yet.
    case registerSession
    /// `admitJoin` on entry, before the join is queued on the membership queue (#97).
    case admitJoinEntry
    /// A failed plan's delayed follow-up, before its `syncNow()`, so a test decides when that
    /// cycle runs instead of racing its 100 ms delay.
    case failedPlanFollowUp
    /// A pending action's answer (`finishActionResponse`), before it checks its ticket.
    case actionResponse
    /// A sync cycle after its frames were enqueued and before its `endSync` hop, while the cycle
    /// still owns the keeper's sync flag: holds a cycle in flight.
    case cycleBeforeEndSync
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
}

/// Adapts Transport events to LandKeeper calls.
public actor TransportAdapter<State: StateNodeProtocol>: TransportDelegate {

    private let keeper: LandKeeper<State>

    /// Whether in-turn sync is on for this adapter (`InTurnSync`): its `inTurnSync` init argument
    /// and the `IN_TURN_SYNC` environment, decided once at init; an explicit off wins. This is the
    /// single source of truth for the switch: the keeper follows it through
    /// `runsSyncPhaseInTurn(of:)`.
    public nonisolated let inTurnSyncEnabled: Bool

    /// How this adapter plans its syncs, for the record header (`ReevaluationSyncConfig`).
    public nonisolated var syncConfigForRecord: ReevaluationSyncConfig {
        ReevaluationSyncConfig(
            mergedBroadcastFrame: stateUpdateEncoder.encoding == .opcodeMessagePack,
            fullSnapshot: syncStrategy == .fullSnapshot
        )
    }

    /// With in-turn sync off: a private actor whose default executor this adapter uses, so it
    /// keeps an executor of its own, separate from the keeper's (the legacy behaviour).
    private nonisolated let ownExecutorHost: AdapterExecutorHost?

    /// With in-turn sync on, the keeper's serial executor: the keeper can then call
    /// `runSyncPhaseInTurn` synchronously inside its own turn (`assumeIsolated`). With it off,
    /// an executor of the adapter's own.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        ownExecutorHost?.unownedExecutor ?? keeper.unownedExecutor
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

    /// The back-pressure rule of `withSyncState` for in-turn sync phases: the writer still holds
    /// a sync cycle element from an earlier phase (`hasPendingStateElement`). Event elements are
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
    /// Sync cycles skipped before `beginSync` (see `SyncSkipCounts`).
    var syncSkips = SyncSkipCounts()
    /// Syncs skipped for writer back-pressure on a land without periodic sync, to run once the
    /// writer drained its sync cycle elements (see `deferSyncForOutboundBacklog`).
    var backlogDeferredSyncNow = false
    var backlogDeferredBroadcastOnly = false
    var backlogRetryScheduled = false
    /// Sync Tasks this adapter started in the background (deferred retry, follow-ups), by id,
    /// until they finish: `waitForSyncQuiescenceForTesting` awaits them.
    var backgroundSyncTasks: [UInt64: Task<Void, Never>] = [:]
    var nextBackgroundSyncTaskID: UInt64 = 0
    /// `landID` for the outbound extension's logs.
    var landIDForOutbound: String { landID }
    /// Logger for the outbound extension.
    var outboundLogger: Logger { logger }

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
        /// The opcode 107 body: the event falls back to its own frame.
        case mergedBody
        /// Every encoding: the event is lost.
        case all
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

    /// Tests only: whether dirty tracking is on now (auto dirty tracking may have switched it).
    func dirtyTrackingEnabledForTesting() -> Bool {
        enableDirtyTracking
    }

    /// Tests only: how many syncs the change-object metrics measured.
    func changeMetricsSamplesForTesting() -> UInt64 {
        dirtyTrackingMetricsState.syncCount
    }

    /// Dirty fields of failed plans, merged into the next plan's (tests).
    func carriedDirtyFieldsForTesting() -> Set<String> {
        carriedDirtyFields
    }

    /// Row addressing: the root fields every plan diffs again (`rowRetryFields`).
    func rowRetryFieldsForTesting() -> Set<String> {
        rowRetryFields
    }

    /// Row addressing: committed plans in a row that dropped a row (`consecutiveRowRepairs`).
    func consecutiveRowRepairsForTesting() -> Int {
        consecutiveRowRepairs
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

    /// What clients were last sent for the broadcast fields (tests): the typed tables as a
    /// snapshot when the broadcast diff runs on them, the engine's broadcast cache otherwise.
    func lastSentBroadcastSnapshotForTesting() -> StateSnapshot? {
        broadcastTables.map(\.lastSentSnapshot) ?? syncEngine.cachedBroadcastSnapshotForTesting
    }

    /// Installs `syncEncodeFaultForTesting` (tests only).
    func setSyncEncodeFaultForTesting(_ fault: (@Sendable (PlayerID) -> Bool)?) {
        syncEncodeFaultForTesting = fault
    }

    /// How long teardown waits for queued frames to reach the transport.
    static var outboundTeardownTimeout: Duration { .seconds(2) }
    private let landID: String
    private let codec: any TransportCodec
    private let messageEncoder: any TransportMessageEncoder
    private let stateUpdateEncoder: any StateUpdateEncoder
    /// `stateUpdateEncoder` as a sequenced encoder (#332), cast once here instead of per recipient.
    /// Every built-in encoder is one; a sequence is planned only with `tracksSyncLag`.
    private let sequencedStateUpdateEncoder: (any SyncSequencedStateUpdateEncoder)?
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
    /// A resync was due in a plan that wasn't full: the next cycle runs full.
    private var syncLagFullPlanRequested = false
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
    /// Resync snapshots not sent because they didn't encode whole, and the 4012 closes.
    package private(set) var syncLagSnapshotEncodeFailures = 0
    package private(set) var syncLagUnencodableCloses = 0
    package private(set) var syncLagUnresponsiveCloses = 0
    package private(set) var syncLagDroppedAcks = 0
    package private(set) var syncLagDroppedEvents = 0
    /// The lag timer (#332): runs while a session is tracked. Read-only: it closes what is due
    /// and requests a sync on a land without periodic sync; the plan does the rest.
    private var syncLagTimer: Task<Void, Never>?
    private var syncLagTimerEpoch: UInt64 = 0
    /// A sync the timer requested hasn't run yet (one at a time).
    private var syncLagTimerSyncRequested = false
    package private(set) var syncLagTimerSyncRequests = 0
    /// The timer's period; tests shorten it.
    package var syncLagTimerInterval: Duration = .milliseconds(250)
    private let pathHashes: [String: UInt32]?
    private var syncEngine = SyncEngine(for: State.self)
    /// The broadcast diff on the typed tables (`TransportEnvConfig.useSyncTables`, delta strategy
    /// only), or nil: today's snapshot diff. With it, the sync path never reads the engine's
    /// broadcast cache (`SyncEngine.broadcastCacheRetired`); per-player fields stay on the engine.
    private let broadcastTables: SyncTableBroadcastDiff<State>?
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
    /// - Skip `clearDirty()` in `LandKeeper.beginSync(clearDirtyFlags:)` to avoid recursive reset cost
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

    /// Enable logging of changed-vs-unchanged object ratio per sync.
    /// Disabled by default. Enable with ENABLE_CHANGE_OBJECT_METRICS=true.
    private let enableChangeObjectMetrics: Bool
    /// Log interval (sync cycles) for change-object metrics.
    private let changeObjectMetricsLogEvery: Int
    /// Dirty tracking metrics calculator (pure computation, no async/await).
    private let dirtyTrackingMetrics: DirtyTrackingMetrics
    /// Mutable state for dirty tracking metrics calculation.
    private var dirtyTrackingMetricsState: DirtyTrackingMetrics.State
    
    /// Auto-switch dirty tracking based on changeRateEma (hysteresis).
    /// Enabled by default. Set AUTO_DIRTY_TRACKING=false to disable.
    private let enableAutoDirtyTracking: Bool
    /// When dirty tracking is ON and EMA >= this threshold for N consecutive samples, switch OFF.
    private let autoDirtyOffThreshold: Double
    /// When dirty tracking is OFF and EMA <= this threshold for N consecutive samples, switch ON.
    private let autoDirtyOnThreshold: Double
    /// Required consecutive samples before switching dirty tracking mode: the configured syncs,
    /// in samples (`DirtyTrackingSampling.requiredSamples(forSyncs:)`).
    private let autoDirtyRequiredConsecutiveSamples: Int
    /// Which syncs collect change-object metrics (`AUTO_DIRTY_SAMPLE_EVERY`, #391).
    private let dirtyTrackingSampling: DirtyTrackingSampling
    /// Syncs that could collect change-object metrics so far, counted by the commit; the plan
    /// reads it to decide whether its sync is a sample.
    private var changeMetricsSyncIndex: UInt64 = 0
    private var autoDirtyOffCandidateCount: Int = 0
    private var autoDirtyOnCandidateCount: Int = 0


    /// Expected schema hash for version verification.
    /// If set, clients must provide matching schemaHash in join metadata.
    private var expectedSchemaHash: String?

    /// The state-update features this adapter's frames use (`TransportEncodingConfig
    /// .stateUpdateFeatures`): a join must declare each in its metadata's `stateUpdateFeatures`,
    /// and `joinResponse` echoes them.
    package nonisolated let stateUpdateFeatures: [String]

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
    private var actionResponsesFinishedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

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
        var heldEvents: [Data] = []
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
        /// Committed plans in which its firstSync did not encode, not even empty: it was not
        /// flipped (#69). It stays ready to flip, so the next full cycle retries it, but it no
        /// longer asks for join sync turns of its own (`isAwaitingJoinSync`): its retries are
        /// the repair follow-ups (at most `syncFailedPlanFollowUpLimit` on a land without
        /// periodic sync) and the land's own cycles, until the join flip timeout.
        var encodeSkips = 0

        var isReadyToFlip: Bool { consumed && transportRegistered && !failed }
        /// Ready, and asking for a sync turn of its own (`hasJoinsAwaitingSync`).
        var isAwaitingJoinSync: Bool { isReadyToFlip && encodeSkips == 0 }
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
    /// admitted from now on.
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
    }

    /// Admissions made by the keeper's in-turn callback (tests only).
    private(set) var inTurnAdmissionCountForTesting = 0

    /// Set when a sync plan failed (its encodes may have allocated key slots in the encoders'
    /// dynamic key tables that no client learned, the frames were never sent) or a committed
    /// plan dropped a frame it had encoded for (`SyncPhasePlan.leavesKeyTablesAhead`).
    ///
    /// The next committed full plan types every recipient's update `.firstSync`, even when empty:
    /// the encoders reset the scope's key table and the client clears its key map for that scope,
    /// then the frame defines every key it uses. Its patches are the plan's normal diff against
    /// the cache (dirty-only with dirty tracking); clients apply a firstSync's patches onto their
    /// view like a diff. Cleared by that commit (one with at least one recipient). While it is
    /// set, a broadcast-only cycle runs as a full cycle.
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

    /// Dirty fields of full plans that failed: their `beginSync` cleared the flags, but nothing
    /// was committed. Merged into every plan's dirty fields (`planDirtyFields(of:)`) until a full
    /// plan commits, so a failed plan loses no change. While non-empty, a broadcast-only cycle runs
    /// as a full cycle.
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
    /// Opcode 107: sequences of in-turn events with no recipient, until the next recorded output
    /// lists them (`eventsNotQueued`).
    private var syncStreamUnqueuedEvents: [Int64] = []
    /// Opcode 107: sequences of in-turn events that had recipients but were not merged (sent
    /// alone, or lost), until the next recorded output lists them (`eventsNotMerged`).
    private var syncStreamUnmergedEvents = ReevaluationUnmergedEvents()
    /// Tests only: plans that filled a `SyncOutputDigestInput`.
    private(set) var syncOutputDigestCountForTesting = 0

    /// Sync cycles that requested `beginSync`, counted in the turn that starts the hop (tests:
    /// once the count is readable, that cycle is suspended in or past its `beginSync` hop).
    private(set) var beginSyncRequests = 0

    /// Failed plans in a row after which no delayed follow-up is scheduled any more.
    static var syncFailedPlanFollowUpLimit: Int { 3 }

    /// Delay of the follow-up after a failed plan on a land without periodic sync.
    static var syncFailedPlanFollowUpDelay: Duration { .milliseconds(100) }

    /// Failed plans in a row (any kind), for the follow-up limit.
    private var consecutiveFailedPlans = 0

    /// Row addressing: committed plans in a row that dropped a row, for the follow-up limit of
    /// the row repair (`syncFailedPlanFollowUpLimit`), apart from `consecutiveFailedPlans`, so a
    /// row that never encodes doesn't use up a failed plan's follow-ups. Back to zero when a plan
    /// commits without dropping a row.
    private var consecutiveRowRepairs = 0

    /// Row addressing: the last committed full plan dropped a row (read right after the commit).
    private var lastCommitDroppedRows = false

    /// Row addressing: the root fields with a row dropped by a committed plan, which every later
    /// plan diffs (with dirty tracking a plan visits only its fields, and a commit clears the
    /// dirty flags). A field leaves the set when a plan's diff of it completed with no row dropped
    /// and no extraction drop. Written in the commit's segment.
    private var rowRetryFields: Set<String> = []

    /// Row addressing: the rows whose patches did not encode in the plan being made (see
    /// `encodeDroppingUnencodablePatches`); reset by `makePlan`.
    private var planFailedRows: Set<SyncRowRef> = []

    /// When the last dropped-updates error was logged (rate limit).
    private var lastDroppedUpdatesLog: ContinuousClock.Instant?

    /// Patches, updates or fields dropped because they did not encode or extract, since the
    /// adapter started (diagnostics). Each is data loss: the field stays stale on clients until it
    /// changes.
    private(set) var syncDroppedUpdates = 0

    /// Tests only: per-player state updates of a player for which this returns `true` fail to
    /// encode (any update type, any encoding).
    private var syncEncodeFaultForTesting: (@Sendable (PlayerID) -> Bool)?
    /// The phase times of the last committed full plan; nil while profiling is off.
    private(set) var lastSyncPhaseTimesForTesting: SyncPhaseTimes?

    /// Sync plans that failed (threw) since the adapter started (diagnostics).
    private(set) var syncFailedPlans = 0

    /// When the last "sync plan failed" error was logged (rate limit).
    private var lastSyncFailureLog: ContinuousClock.Instant?

    /// Tests only: called at the end of every sync plan, after its diffs were staged and its
    /// frames encoded. A throw fails the plan there.
    private var syncPlanFaultForTesting: (@Sendable () throws -> Void)?
    /// Thrown by a joiner's firstSync plan (`planFirstSync`) when set (tests only).
    private var firstSyncPlanFaultForTesting: (@Sendable () throws -> Void)?

    /// Sets the sync-lag thresholds (the host, before any session joins). Tracking runs only
    /// with an encoding that carries the sync sequence (`TransportEncodingConfig.syncSequence`).
    package func setSyncLagPolicy(_ policy: SyncLagPolicy) {
        syncLagPolicy = policy
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

    /// Membership queue prevents stale join/leave work from delivering after rejoin.
    /// See Notes/plans/2026-02-01-membership-queue-reconnect.md.
    private var membershipQueueTail: Task<Void, Never>?

    /// Manager for pending server events (targeted and broadcast).
    /// Encoded once when queued to avoid per-session re-encoding. Cleared after each sync.
    private var pendingEventManager = PendingEventManager()

    /// Debug freeze bookkeeping (see `TransportAdapter+DebugFreeze.swift`).
    var debugFreezeState = DebugFreezeState<State>()

    /// Whether to merge server events with state update (opcode 107). True when state update encoding is opcodeMessagePack.
    private var useStateUpdateWithEvents: Bool {
        stateUpdateEncoder.encoding == .opcodeMessagePack
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
        inTurnSync: Bool = true,
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
            suppressMissingPathHashesWarning: suppressMissingPathHashesWarning, inTurnSync: inTurnSync,
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
        inTurnSync: Bool = true,
        logger: Logger? = nil,
        joinsThroughRouter: Bool
    ) {
        self.keeper = keeper
        self.authenticatesPlayers = authenticatesPlayers
        let inTurnSyncEnabled = inTurnSync && InTurnSync.isEnabled()
        self.inTurnSyncEnabled = inTurnSyncEnabled
        self.ownExecutorHost = inTurnSyncEnabled ? nil : AdapterExecutorHost()
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
        // `rowAddressing` takes effect only where every join completes in a turn: in-turn sync
        // (the land manager turns it off for a replay keeper) and joins through the router. Its
        // rows are the sync tables' slots, so it turns the tables on (their frames are today's,
        // byte for byte), which needs the delta strategy.
        let rowAddressingRequested = encodingConfig?.effective(pathHashes: pathHashes).rowAddressing ?? false
        let rowAddressing = rowAddressingRequested && inTurnSyncEnabled && joinsThroughRouter
            && envConfig.syncStrategy == .delta
        let usesSyncTables = (envConfig.useSyncTables || rowAddressing) && envConfig.syncStrategy == .delta
        self.rowAddressing = rowAddressing
        if let encodingConfig = encodingConfig?.withRowAddressing(rowAddressing) {
            self.codec = encodingConfig.makeCodec()
            self.messageEncoder = encodingConfig.makeMessageEncoder(
                eventHashes: eventHashes,
                clientEventHashes: clientEventHashes
            )
            // Built here, at registration, and kept on the encoder: frames go out in the land's
            // canonical order (`CanonicalPatchOrder`).
            self.stateUpdateEncoder = applyingCanonicalOrder(CanonicalPatchOrder.forState(State.self), to: encodingConfig.makeStateUpdateEncoder(
                pathHashes: pathHashes,
                warnIfMissingPathHashes: !suppressMissingPathHashesWarning,
                atomicLayout: AtomicLayoutTable.forState(State.self),
                unmappedPaths: unmappedPathCounter
            ))
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
            self.messageEncoder = JSONTransportMessageEncoder()
            self.stateUpdateEncoder = applyingCanonicalOrder(CanonicalPatchOrder.forState(State.self), to: stateUpdateEncoder)
            self.pathHashes = pathHashes
            self.tracksSyncLag = false
            self.stateUpdateFeatures = []
        }
        self.sequencedStateUpdateEncoder = self.stateUpdateEncoder as? any SyncSequencedStateUpdateEncoder

        self.enableLegacyJoin = enableLegacyJoin

        self.enableDirtyTracking = envConfig.enableDirtyTracking
        self.useSnapshotForSync = envConfig.useSnapshotForSync
        self.syncStrategy = envConfig.syncStrategy
        if usesSyncTables {
            // The encoder's own path trie, so the diff's patches carry the splits it would compute.
            let hasher = (self.stateUpdateEncoder as? any PathSplittingStateUpdateEncoder)?.splittingPathHasher
            let tables = SyncTableBroadcastDiff<State>(pathCursor: hasher?.rootCursor)
            tables.emitsRowCreates = rowAddressing
            self.broadcastTables = tables
            self.syncEngine.broadcastCacheRetired = true
        } else {
            self.broadcastTables = nil
        }
        self.enableChangeObjectMetrics = envConfig.enableChangeObjectMetrics
        self.changeObjectMetricsLogEvery = envConfig.changeObjectMetricsLogEvery
        let sampling = DirtyTrackingSampling(every: envConfig.autoDirtySampleEvery)
        self.dirtyTrackingSampling = sampling
        self.dirtyTrackingMetrics = DirtyTrackingMetrics(emaAlpha: sampling.sampledAlpha(envConfig.changeObjectMetricsEmaAlpha))
        self.dirtyTrackingMetricsState = DirtyTrackingMetrics.State()
        self.enableAutoDirtyTracking = envConfig.enableAutoDirtyTracking
        self.autoDirtyOffThreshold = envConfig.autoDirtyOffThreshold
        self.autoDirtyOnThreshold = envConfig.autoDirtyOnThreshold
        self.autoDirtyRequiredConsecutiveSamples = sampling.requiredSamples(forSyncs: envConfig.autoDirtyRequiredConsecutiveSamples)
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
            landID: landID
        )
        
        // Initialize event sending pipeline
        self.eventSendingPipeline = EventSendingPipeline(
            messageEncoder: self.messageEncoder,
            codec: self.codec,
            landID: landID,
            logger: self.logger
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
            "syncStrategy": .string(envConfig.syncStrategy.rawValue),
            "stateUpdateFeatures": .string(self.stateUpdateFeatures.joined(separator: ",")),
            "changeObjectMetrics": .string(envConfig.enableChangeObjectMetrics ? "on" : "off"),
            "autoDirtyTracking": .string(envConfig.enableAutoDirtyTracking ? "on" : "off"),
            "autoDirtyOffThreshold": .string(String(format: "%.3f", envConfig.autoDirtyOffThreshold)),
            "autoDirtyOnThreshold": .string(String(format: "%.3f", envConfig.autoDirtyOnThreshold)),
            "autoDirtyRequiredSamples": .string("\(envConfig.autoDirtyRequiredConsecutiveSamples)"),
            "autoDirtySampleEvery": .string("\(envConfig.autoDirtySampleEvery)")
        ])
        if rowAddressingRequested && !rowAddressing {
            self.logger.warning("Row addressing requested but not in effect: it needs in-turn sync, joins through the router and the delta sync strategy; this land sends today's entries", metadata: [
                "landID": .string(landID),
                "inTurnSync": .string(inTurnSyncEnabled ? "on" : "off"),
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

    /// The features of `required` that the join metadata's `stateUpdateFeatures` (a list of
    /// strings) doesn't declare; nil when none is missing.
    nonisolated static func missingStateUpdateFeatures(required: [String], metadata: [String: AnyCodable]?) -> [String]? {
        guard !required.isEmpty else { return nil }
        let raw = metadata?[StateUpdateFeature.metadataKey]?.base
        let declared: Set<String>
        if let strings = raw as? [String] {
            declared = Set(strings)
        } else if let values = raw as? [AnyCodable] {
            declared = Set(values.compactMap { $0.base as? String })
        } else if let values = raw as? [Any] {
            declared = Set(values.compactMap { $0 as? String })
        } else {
            declared = []
        }
        let missing = required.filter { !declared.contains($0) }
        return missing.isEmpty ? nil : missing
    }

    /// The join error's message for missing state-update features.
    nonisolated static func missingFeaturesMessage(_ missing: [String]) -> String {
        "unsupported state update encoding: missing \(missing.joined(separator: ", "))"
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

    func _onDisconnectImpl(sessionID: SessionID, clientID: ClientID) async {
        do {
            try await enqueueMembership {
                await self.handleDisconnectQueued(sessionID: sessionID, clientID: clientID)
            }
        } catch {
            logger.error("❌ Membership queue failed during disconnect", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string(String(describing: error))
            ])
        }
    }

    private func handleDisconnectQueued(sessionID: SessionID, clientID: ClientID) async {
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

            // Now call keeper.leave() which will trigger syncBroadcastOnly()
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
                recordSyncStreamClear(playerID, outsideTurn: true)
                initialSyncingPlayers.removeValue(forKey: playerID)

                // Release playerSlot for this player
                membershipCoordinator.releasePlayerSlot(playerID: playerID)

                logger.info("Client disconnected: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
            } else {
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

    /// Register a session that has been authenticated and joined via LandRouter.
    /// This bypasses the internal join handshake logic of TransportAdapter.
    ///
    /// It also bypasses the admission, and with it newest wins (#92): the player's other
    /// sessions stay members. Joins through `performJoin` (the router and the legacy path)
    /// supersede them.
    func _registerSessionImpl(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?,
        acceptedConnectionGeneration: UInt64? = nil
    ) async {
        // Rebinding the session to another player starts a new generation: work captured for
        // the previous player's binding (an initial sync reading the state) must not act on it.
        if let previous = membershipCoordinator.playerID(for: sessionID), previous != playerID {
            sessionTickets.end(sessionID)
            syncLag.removeValue(forKey: sessionID)
        }
        _ = membershipCoordinator.registerPlayer(
            sessionID: sessionID,
            playerID: playerID,
            authInfo: authInfo
        )
        membershipCoordinator.registerClient(sessionID: sessionID, clientID: clientID)

        // Record the session's connection generation (see `connectionGenerations`). Group
        // targets are expanded from this adapter's membership, not from the transport's maps.
        endedSessions.remove(sessionID)
        if let webSocketTransport = transport as? WebSocketTransport {
            let current = await webSocketTransport.registerSession(sessionID, for: playerID)
            connectionGenerations[sessionID] = acceptedConnectionGeneration ?? current
        } else if let acceptedConnectionGeneration {
            connectionGenerations[sessionID] = acceptedConnectionGeneration
        }

        logger.info("Session registered via Router: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
    }

    /// Ends every session ticket, at the land's teardown: work still holding one (an initial
    /// sync) commits nothing for the destroyed land.
    package func endSessionTicketsForTeardown() {
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
    /// This ensures syncNow() and syncBroadcastOnly() skip this player during initial sync.
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
        inTurn: (joinSequence: Int64?, joinResponse: @Sendable (PlayerID, Int32) -> Data?, joinDeadline: ContinuousClock.Instant?)? = nil
    ) -> Int32 {
        supersedeSessions(of: playerID, keeping: sessionID)
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
                consumed: inTurn.joinSequence == nil
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
    private func startJoinWaiter(sessionID: SessionID, ticket: Ticket<SessionID>, joinDeadline: ContinuousClock.Instant?) {
        joinWaiters[sessionID]?.resolve(.failure(.superseded))
        let waiter = JoinWaiter(ticket: ticket)
        joinWaiters[sessionID] = waiter
        let deadline = joinDeadline ?? JoinTimeoutConfig.budget.map { ContinuousClock.now + $0 }
        guard let timeout = joinFlipTimeoutForTesting ?? JoinTimeoutConfig.flipWait(deadline: deadline) else { return }
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
    /// left of the budget.
    func endJoinBeforeAdmission(_ sessionID: SessionID, finalFrame: Data?, attemptEnd: JoinAttemptEnd) -> Bool {
        guard expectedAdmissions[sessionID] == nil,
              joiningSessions[sessionID] == nil,
              membershipCoordinator.playerID(for: sessionID) == nil
        else { return false }
        // Not `endedSessions` alone: it evicts its oldest entries, and an admission can stay
        // queued while thousands of the land's sessions end.
        attemptEnd.markEnded()
        if let finalFrame {
            sendFinalFrameAndClose(finalFrame, to: sessionID)
        } else {
            endedSessions.insert(sessionID)
            let transport = self.transport
            Task { await transport.closeSession(sessionID) }
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
        joiningSessions
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
            if result.failed {
                failInTurnJoin(sessionID: sessionID, reason: .onJoinFailed)
            } else {
                joiningSessions[sessionID]?.inTurn?.consumed = true
            }
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
    private(set) var staleJoinAttemptsRefused = 0

    /// Ends every session of `playerID` other than `sessionID` (newest wins, #92). For the game
    /// this is OnLeave then OnJoin: the keeper's join already left the old entry. Here, in the
    /// admission segment:
    /// - each old session leaves the membership (it stops being a recipient and its inbound
    ///   finds no player), is ended (its frames are dropped) and its connection is closed; its
    ///   later disconnect callback finds no membership, so it clears nothing and doesn't leave
    ///   the keeper again;
    /// - an old session still joining loses its mark;
    /// - the player's per-player sync state (cache, firstSync mark, initial-sync mark) is
    ///   cleared, and the clear recorded, so the new session's firstSync starts from empty like
    ///   a first join. The player slot is kept.
    private func supersedeSessions(of playerID: PlayerID, keeping sessionID: SessionID) {
        let superseded = membershipCoordinator.sessionIDs(for: playerID).filter { $0 != sessionID }
        guard !superseded.isEmpty else { return }
        let transport = self.transport
        for old in superseded {
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
            Task { await transport.closeSession(old) }
        }
        syncEngine.clearCacheForDisconnectedPlayer(playerID)
        recordSyncStreamClear(playerID)
        initialSyncingPlayers.removeValue(forKey: playerID)
    }

    /// The keeper's in-turn admission (`LandKeeperTransport.admitJoiningSession`), on the
    /// keeper's executor. Admits only a join `performJoinQueued` is waiting for.
    func admitJoiningSessionIsolated(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        guard let expected = expectedAdmissions.removeValue(forKey: sessionID) else { return .notAdmitted }
        _ = admitJoining(
            sessionID: sessionID,
            playerID: playerID,
            authInfo: expected.authInfo,
            inTurn: expected.joinResponse.map { (joinSequence: joinSequence, joinResponse: $0, joinDeadline: expected.joinDeadline) }
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

        // Attempt to join (updates keeper.players). On the in-turn path the keeper admits the
        // session inside the join, in the segment of its state change (`admitJoiningSession`);
        // otherwise it is admitted below, right after the join returns, before any await.
        expectedAdmissions[sessionID] = ExpectedAdmission(authInfo: authInfo, joinResponse: joinResponse, joinDeadline: joinDeadline)
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
                await holds.at(.registerSession)
            }

            // Register session
            await registerSession(
                sessionID: sessionID,
                clientID: clientID,
                playerID: playerID,
                authInfo: authInfo,
                connectionGeneration: connectionGeneration
            )

            if completesInTurn {
                // Ready once registered (and its OnJoin consumed): a land without periodic
                // sync runs the sync phase that flips it; one with it flips at its next sync.
                // Same segment as the check: the record must still be this admission's.
                if let ticket = admittedTicket, joiningSessions[sessionID]?.ticket == ticket {
                    joiningSessions[sessionID]?.inTurn?.transportRegistered = true
                }
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
    /// with a newer attempt. Admitting it would supersede that newer session. `playerID` is the
    /// requested one (the keeper's decision comes later); a land that maps players in `CanJoin`
    /// gets only the ended-session check.
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
                sendFinalFrameAndClose(data, to: sessionID)
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
                enqueueOutbound(errorData, to: sessionID)
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

                        if let resolverError = error as? ResolverExecutionError {
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
                            enqueueOutbound(errorData, to: sessionID)
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

    /// Send server event to specified target. When opcode 107 is enabled (opcodeMessagePack),
    /// events are queued and sent merged with the next state update instead of separate frames.
    /// When body encoding fails (e.g. message encoder is JSON in a hybrid config), falls back to sending a separate frame.
    ///
    /// **When fallback is used:** In typical production the message encoder is MessagePack (clients use the encoding
    /// from joinResponse, so with `TransportEncodingConfig.messagepack` body encoding succeeds and events are merged).
    /// The fallback matters for hybrid configs only: `message: .json` or `.opcodeJsonArray` with `stateUpdate: .opcodeMessagePack`
    /// (e.g. debugging or migration), where `encodeServerEventBody` returns nil.
    ///
    /// **Core issue (why fallback is required):** Opcode 107 merges events with state updates as a MessagePack array.
    /// That requires an event "body" as `MessagePackValue`. `encodeServerEventBody` can only produce that when the
    /// message encoder is MessagePack. If the message encoder is JSON or opcodeJsonArray, it encodes to JSON bytes
    /// then tries `unpack(JSON bytes)` as MessagePack, which fails → returns nil. Without fallback, the event would
    /// be dropped silently. We therefore fall through to the normal send path and send the event as a separate frame.
    public func sendEvent(_ event: AnyServerEvent, to target: SwiftStateTree.EventTarget) async {
        enqueueEventSynchronously(event, to: target)
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
        // Queue mode (opcode 107)
        if useStateUpdateWithEvents {
            if fault == nil, let body = encodeServerEventBody(event) {
                let queued = eventSendingPipeline.queueForMergedSend(
                    eventBody: body,
                    target: target,
                    pendingEventManager: &pendingEventManager,
                    membershipCoordinator: membershipCoordinator,
                    digest: digest
                )
                return queued ? .queued : .noRecipient
            }
            // The body did not encode: the event goes out as its own frame, or is lost.
            return sendEventImmediately(event, to: target, failsEncoding: fault == .all) ? .sentAlone : .lost
        }

        // Immediate mode: encoded and enqueued now
        sendEventImmediately(event, to: target, failsEncoding: fault == .all)
        return .immediate
    }

    /// Where `enqueueEventSynchronously` put an event.
    enum EventEnqueueOutcome: Equatable {
        /// Queued for the next merged frame (opcode 107).
        case queued
        /// Opcode 107, and nothing to queue: no recipient (`.players([])`, a client without a
        /// session).
        case noRecipient
        /// Opcode 107, but the body did not encode: sent as its own frame.
        case sentAlone
        /// Opcode 107, but the body did not encode, and neither did its own frame: lost.
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
    /// Failure bookkeeping is as in `withSyncState` (`consecutiveFailedPlans`, follow-up limit),
    /// but the repair is the keeper's: `.failed(repairAllowed:)` tells a keeper without periodic
    /// sync whether to schedule a repair sync-only turn.
    func runSyncPhaseInTurnIsolated<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        let digestsEvents = useStateUpdateWithEvents && !events.isEmpty && keeperRecordsSyncStream()
        for item in events {
            let digest = digestsEvents ? Self.canonicalEvent(item) : nil
            let outcome = enqueueEventSynchronously(item.event, to: item.target, digest: digest)
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
        if writerHoldsEarlierElementForInTurnSync() {
            syncSkips.outboundBacklog += 1
            profilerCounters?.incrementSyncSkipsBacklog()
            profilerCounters?.incrementSyncDeferredTurns()
            return .deferredBackPressure
        }
        if debugDeferSyncIfFrozen(broadcastOnly: false) { return .skipped }
        profilerCounters?.setSessionCounts(
            connected: membershipCoordinator.connectedSessions.count,
            joined: membershipCoordinator.joinedCount()
        )
        guard !membershipCoordinator.isEmpty else { return .skipped }
        guard let state = state as? State else {
            preconditionFailure("runSyncPhaseInTurn called with a state of another land type")
        }
        // Read once: the auto-switch in the commit may change `enableDirtyTracking`.
        let clearDirtyFlags = enableDirtyTracking
        let joiners = readyInTurnJoins(limit: joinFlipBudgetForTesting ?? JoinFlipConfig.budget).map { entry in
            SyncPhaseJoiner(
                recipient: SyncPhaseRecipient(sessionID: entry.sessionID, playerID: entry.joining.playerID),
                ticket: entry.joining.ticket,
                joinResponse: entry.joining.inTurn?.joinResponse ?? Data()
            )
        }
        do {
            try runFullSyncPhase(state: state, read: inTurnSyncOutputRead(), joiners: joiners)
            consecutiveFailedPlans = 0
            if lastCommitDroppedRows {
                // Row addressing: a row was dropped. Its field is in the retry set; a land without
                // periodic sync gets a follow-up while the row repairs are within the limit.
                lastCommitDroppedRows = false
                consecutiveRowRepairs += 1
                if consecutiveRowRepairs <= Self.syncFailedPlanFollowUpLimit {
                    return .committedWithRepairPending(clearDirtyFlags: clearDirtyFlags)
                }
            } else {
                consecutiveRowRepairs = 0
            }
            return .committed(clearDirtyFlags: clearDirtyFlags)
        } catch {
            logger.error("Sync operation failed", metadata: [
                "message": .string("❌ In-turn sync phase failed"),
                "error": .string("\(error)")
            ])
            consecutiveFailedPlans += 1
            return .failed(repairAllowed: consecutiveFailedPlans <= Self.syncFailedPlanFollowUpLimit)
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
    /// This is the fallback path when opcode 107 is disabled or encoding fails.
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
                    enqueueOutbound(data, toSessions: withoutPendingSyncLag(sessionIDs(for: .player(playerID), holding: data)))
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
            enqueueOutbound(data, toSessions: withoutPendingSyncLag(sessionIDs(for: transportTarget, holding: data)))
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

    /// Encode a server event body without opcode (MessagePack array [direction, type, payload, ...]).
    /// Succeeds only when the message encoder is MessagePack (typical production: clients use encoding from joinResponse).
    /// Returns nil when the message encoder is JSON or opcodeJsonArray: we encode to bytes then try MessagePack unpack,
    /// which fails. Caller must then send the event as a separate frame (see sendEvent).
    private func encodeServerEventBody(_ event: AnyServerEvent) -> MessagePackValue? {
        return encodingPipeline.encodeServerEventBody(event)
    }

    private func encodeStateUpdate(
        update: StateUpdate,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope
    ) throws -> Data {
        if let syncSeq = planSyncSeq {
            guard let sequenced = sequencedStateUpdateEncoder else {
                preconditionFailure("a sync sequence planned with an encoder that can't carry it")
            }
            return try sequenced.encode(
                update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: scope, syncSeq: syncSeq
            )
        }
        return try encodingPipeline.encodeStateUpdate(
            update: update,
            playerID: playerID,
            playerSlot: playerSlot,
            scope: scope
        )
    }

    /// Build MessagePack frame [107, stateUpdatePayload, eventsArray]. Returns nil on failure (caller should send state only).
    private func buildStateUpdateWithEventBodies(
        stateUpdateData: Data,
        eventBodies: [MessagePackValue],
        allowEmptyEvents: Bool = false
    ) -> Data? {
        return encodingPipeline.buildStateUpdateWithEventBodies(
            stateUpdateData: stateUpdateData,
            eventBodies: eventBodies,
            allowEmptyEvents: allowEmptyEvents
        )
    }

    private func buildStateUpdateWithEventBodies(
        stateUpdateArray: [MessagePackValue],
        eventBodies: [MessagePackValue],
        allowEmptyEvents: Bool = false
    ) -> Data? {
        return encodingPipeline.buildStateUpdateWithEventBodies(
            stateUpdateArray: stateUpdateArray,
            eventBodies: eventBodies,
            allowEmptyEvents: allowEmptyEvents
        )
    }

    /// Appends one event frame (opcode 103) per body for `sessionID`.
    private func appendEventFrames(
        _ eventBodies: [MessagePackValue],
        to sessionID: SessionID,
        into frames: inout [SyncPhaseFrame]
    ) {
        for body in eventBodies {
            guard case .array(let bodyArray) = body else { continue }
            let frame: MessagePackValue = .array([.int(Int64(MessageKindOpcode.event.rawValue))] + bodyArray)
            if let data = try? pack(frame) {
                frames.append(SyncPhaseFrame(data: data, sessionID: sessionID))
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
        // While frozen, the settle cycle is the only sync; defer this one to resume.
        if debugDeferSyncIfFrozen(broadcastOnly: false) { return }
        profilerCounters?.setSessionCounts(
            connected: membershipCoordinator.connectedSessions.count,
            joined: membershipCoordinator.joinedCount()
        )
        guard !membershipCoordinator.isEmpty else {
            return
        }

        // A full cycle diffs every synced field, so it may clear dirty flags. The flag is read
        // here, once: the auto-switch in the commit may change `enableDirtyTracking`.
        let needsFollowUp = await withSyncState(
            clearDirtyFlags: enableDirtyTracking,
            broadcastOnly: false,
            skipLogMessage: "⏭️ Sync skipped: another sync operation is in progress",
            errorLogMessage: "❌ Failed to extract broadcast snapshot"
        ) { state in
            try runFullSyncPhase(state: state, read: legacyCycleRead)
        }
        if needsFollowUp {
            startFollowUpSync()
        }
    }

    /// Starts the follow-up cycle that `withSyncState` asked for, without making the caller of
    /// the current cycle wait for it (on tickless lands that caller is an action's response).
    /// If `beginSync` rejects it, another cycle is in flight: that cycle reads the kept events at
    /// the front of the queue, and its own check after `endSync()` covers anything queued later.
    private func startFollowUpSync() {
        startBackgroundSync { await $0.syncNow() }
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

    /// After a failed plan (a sync cycle's or a joiner's firstSync) on a land without periodic
    /// sync: one follow-up after a short delay, so the repair does not wait for an unrelated
    /// sync request. Bounded by `syncFailedPlanFollowUpLimit` failed plans in a row.
    private func noteFailedPlanForFollowUp() {
        consecutiveFailedPlans += 1
        if !keeper.hasPeriodicSync && consecutiveFailedPlans <= Self.syncFailedPlanFollowUpLimit {
            startDelayedFollowUpSync()
        }
    }

    private func startDelayedFollowUpSync() {
        startBackgroundSync { adapter in
            try? await safeTaskSleep(for: Self.syncFailedPlanFollowUpDelay)
            await adapter.holds.at(.failedPlanFollowUp)
            await adapter.syncNow()
        }
    }

    /// After a back-pressure skip, or a request rejected because a cycle was in flight: a land
    /// with periodic sync gets its next periodic cycle, which covers broadcast-only changes too.
    /// Without periodic sync nothing else would run the skipped cycle, so run it once the
    /// writer has drained its sync cycle elements (coalesced: one pending retry, a full cycle
    /// when any skipped request was full).
    private func deferSyncForOutboundBacklog(broadcastOnly: Bool, afterBusy: Bool = false) {
        // After teardown nothing is sent any more: do not schedule a retry.
        guard !keeper.hasPeriodicSync, !outboundWriter.isFinished else { return }
        if broadcastOnly {
            backlogDeferredBroadcastOnly = true
        } else {
            backlogDeferredSyncNow = true
        }
        guard !backlogRetryScheduled else { return }
        backlogRetryScheduled = true
        let writer = outboundWriter
        startBackgroundSync { adapter in
            // After a busy rejection, let the cycle in flight reach `endSync` first.
            if afterBusy { try? await safeTaskSleep(for: .milliseconds(1)) }
            await writer.waitForSyncCycleDrain()
            await adapter.runBacklogDeferredSync()
        }
    }

    /// Number of deferred retries started so far (tests).
    private(set) var backlogRetryRuns = 0

    private func runBacklogDeferredSync() async {
        backlogRetryRuns += 1
        let runSyncNow = backlogDeferredSyncNow
        let runBroadcastOnly = backlogDeferredBroadcastOnly && !runSyncNow
        backlogDeferredSyncNow = false
        backlogDeferredBroadcastOnly = false
        backlogRetryScheduled = false
        if runSyncNow {
            await syncNow()
        } else if runBroadcastOnly {
            await syncBroadcastOnly()
        }
    }

    /// Sync cycles skipped so far (tests and diagnostics, such as a benchmark checking that every
    /// cycle it requested ran). Not a supported API.
    @_spi(Diagnostics) public func syncSkipCounts() -> SyncSkipCounts {
        syncSkips
    }

    /// Runs `phase` (a sync phase: plan + commit) on a state copy taken by
    /// `LandKeeper.beginSync(clearDirtyFlags:)`.
    ///
    /// Dirty flags are cleared (when `clearDirtyFlags` is set) in the same keeper turn that takes
    /// the copy, so mutations made after it stay dirty for the next cycle (#68). The commit owns
    /// the decision: a committed plan leaves them cleared; a full plan that throws merges them
    /// into the next plan's (`carriedDirtyFields`).
    ///
    /// Returns `true` when the caller must start a follow-up `syncNow` cycle, decided after
    /// `endSync()` returned: a sync request made before that is rejected by `beginSync`, so events
    /// queued up to then (including during the `endSync()` hop) have no other cycle to deliver them.
    /// A follow-up is needed when all of these hold:
    /// - `phase` completed: a cycle that throws every time must not retry forever;
    /// - events are queued now (kept by this cycle or queued after its commit);
    /// - the land has no periodic sync (`LandKeeper.hasPeriodicSync`) whose next cycle delivers them.
    ///
    /// A failed `phase` on a land without periodic sync schedules a delayed follow-up instead
    /// (`startDelayedFollowUpSync`).
    ///
    /// Back-pressure: while the writer still holds a sync cycle element from an earlier cycle,
    /// the cycle is skipped before `beginSync`, so dirty flags and queued events stay for the
    /// next cycle, which diffs against the last state sent. Overload then turns into skipped
    /// cycles instead of a growing writer queue that every later frame waits behind. Event and
    /// action-response frames are not held back. A joiner's firstSync and the debug settle do
    /// not run through here.
    private func withSyncState(
        clearDirtyFlags: Bool,
        broadcastOnly: Bool,
        skipLogMessage: String,
        errorLogMessage: String,
        phase: (State) throws -> Void
    ) async -> Bool {
        if hasPendingStateElement {
            syncSkips.outboundBacklog += 1
            profilerCounters?.incrementSyncSkipsBacklog()
            deferSyncForOutboundBacklog(broadcastOnly: broadcastOnly)
            return false
        }
        beginSyncRequests += 1
        guard let (state, read) = await beginSyncLocatedIfRecording(clearDirtyFlags: clearDirtyFlags) else {
            syncSkips.busy += 1
            profilerCounters?.incrementSyncSkipsBusy()
            // On a land without periodic sync this request may be the only one for changes
            // made after the cycle in flight took its copy (deferred cycles now run in the
            // background, so requests overlap): run it once more after that cycle.
            deferSyncForOutboundBacklog(broadcastOnly: broadcastOnly, afterBusy: true)
            if logger.logLevel <= .debug {
                logger.debug("Sync skipped", metadata: ["message": .string(skipLogMessage)])
            }
            return false
        }

        var completed = false
        do {
            legacyCycleRead = read
            defer { legacyCycleRead = nil }
            try phase(state)
            completed = true
        } catch {
            logger.error("Sync operation failed", metadata: [
                "message": .string(errorLogMessage),
                "error": .string("\(error)")
            ])
        }

        await holds.at(.cycleBeforeEndSync)
        await keeper.endSync()
        if completed {
            consecutiveFailedPlans = 0
        } else {
            noteFailedPlanForFollowUp()
        }
        return completed && pendingEventManager.hasAnyEvents && !keeper.hasPeriodicSync
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

    private func syncLagNow() -> ContinuousClock.Instant {
        syncLagNowForTesting?() ?? .now
    }

    /// The plan's first step (D1): classifies each recipient with its lag state and returns the
    /// recipients the plan sends to. A pending session, newly or still, and one with a close due
    /// are left out (no frames, no events). A resync due is planned in a full plan (the player as
    /// an unsynced recipient, its view typed a resync, every session of the player with it). A
    /// broadcast-only cycle never meets one: it checks `syncLagResyncDue(at:)` first, at the same
    /// `now`, and runs a full plan instead, so the decision and its frame are one plan. Only the
    /// commit writes what it decided.
    private func classifySyncLag(
        _ recipients: [SyncPhaseRecipient],
        fullPlan: Bool,
        now: ContinuousClock.Instant? = nil,
        events: PendingEventManager,
        into plan: inout SyncPhasePlan
    ) -> [SyncPhaseRecipient] {
        guard tracksSyncLag, !syncLag.isEmpty else { return recipients }
        let now = now ?? syncLagNow()
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
                if fullPlan {
                    plan.syncLag.resyncs[recipient.sessionID] = true
                    resyncPlayers.insert(recipient.playerID)
                    kept.append(recipient)
                } else {
                    // Unreachable: the broadcast-only cycle checked at this `now`. Kept as a
                    // fallback that leaves the session out and asks for a full plan.
                    assertionFailure("a resync due in a broadcast-only plan")
                    plan.syncLag.wantsFullPlan = true
                }
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

    /// Moves each resynced session's snapshot (op 3, tagged `isResyncSnapshot`) ahead of its other
    /// frames of the plan, the merged broadcast frame first among them (#332). The client then
    /// applies the whole view before anything else at the resync's sequence: it skips the state
    /// patches of a later frame with that sequence, which the snapshot already holds, and still
    /// reads its key definitions and events. Its ack of the sequence then follows the snapshot.
    ///
    /// With row addressing an unsynced recipient's view (`isFullViewBeforeSharedFrame`) moves the
    /// same way: it holds the committed tables, which the shared frame then brings to live.
    private func putResyncSnapshotsFirst(_ plan: inout SyncPhasePlan) {
        let views = Set(plan.frames.filter(\.isFullViewBeforeSharedFrame).map(\.sessionID))
        for sessionID in Set(plan.syncLag.resyncs.keys).union(views) {
            // No snapshot (it didn't encode whole), or it is already the session's first frame.
            guard let first = plan.frames.firstIndex(where: { $0.sessionID == sessionID }),
                  let snapshot = plan.frames.firstIndex(where: {
                      $0.sessionID == sessionID && ($0.isResyncSnapshot || $0.isFullViewBeforeSharedFrame)
                  }),
                  snapshot > first else { continue }
            plan.frames.insert(plan.frames.remove(at: snapshot), at: first)
        }
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
        guard syncLagTimer == nil else { return }
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
        if wantsSync, !keeper.hasPeriodicSync, !syncLagTimerSyncRequested {
            syncLagTimerSyncRequested = true
            syncLagTimerSyncRequests += 1
            startBackgroundSync { adapter in
                await adapter.runSyncLagTimerSync()
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

    private func runSyncLagTimerSync() async {
        await holds.at(.syncLagTimerSync)
        syncLagTimerSyncRequested = false
        await syncNow()
    }

    /// Sessions with lag state (tests).
    package var syncLagTrackedSessionCount: Int { syncLag.count }

    /// The newest sequence in a session's FIFO, nil when it is empty or untracked (tests).
    package func syncLagLastCommittedSeqForTesting(_ sessionID: SessionID) -> UInt64? {
        syncLag[sessionID]?.unacked.last?.seq
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
            // Caught up since a failed snapshot: what the plan's classification decides now.
            if let session = syncLag[sessionID], session.snapshotEncodeFailures > 0, session.phase == .live,
               case .none = session.decide(now: now, policy: syncLagPolicy) {
                syncLag[sessionID]?.caughtUp()
            }
            syncLag[sessionID]?.committed(seq, at: now)
        }
        // A joined session with no lag state whose full view this plan committed (its own
        // firstSync plan failed, and the cycle served it as an unsynced recipient): tracking
        // starts here, as at a firstSync commit.
        for sessionID in received where syncLag[sessionID] == nil && sessionID != planned.firstSyncSession {
            guard !endedSessions.contains(sessionID), joiningSessions[sessionID] == nil,
                  let playerID = membershipCoordinator.playerID(for: sessionID),
                  plan.staged.firstSyncReceived.contains(playerID) else { continue }
            startSyncLagTracking(sessionID, plan: plan)
        }
        var resynced = false
        var profiled = TransportProfilerCounters.SyncLagWindow(droppedEvents: planned.droppedEvents)
        var unencodable: [SessionID] = []
        for (sessionID, counted) in planned.resyncs where counted {
            guard let playerID = membershipCoordinator.playerID(for: sessionID),
                  planned.failedSnapshots.contains(playerID),
                  let failures = syncLag[sessionID]?.snapshotEncodeFailed() else { continue }
            syncLagSnapshotEncodeFailures += 1
            profiled.snapshotEncodeFailures += 1
            if failures >= SyncLagSession.snapshotEncodeFailureLimit {
                unencodable.append(sessionID)
            }
        }
        for (sessionID, counted) in planned.resyncs where received.contains(sessionID) {
            // A snapshot that didn't encode unstaged the player's mark: the session stays as it
            // was, and the next plan decides again.
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
        if plan.isFullCycle {
            syncLagFullPlanRequested = false
        }
        if planned.wantsFullPlan {
            syncLagFullPlanRequested = true
        }
        for close in planned.closes {
            closeLaggingSession(close.sessionID, code: close.code)
        }
        for sessionID in unencodable {
            closeLaggingSession(sessionID, code: SessionClose.Code.unencodableView)
        }
    }

    /// Whether a tracked session has a resync due at `now`: read-only, the same decision the
    /// plan's classification makes.
    private func syncLagResyncDue(at now: ContinuousClock.Instant) -> Bool {
        guard tracksSyncLag else { return false }
        return syncLag.contains { sessionID, session in
            guard !endedSessions.contains(sessionID) else { return false }
            if case .resync = session.decide(now: now, policy: syncLagPolicy) { return true }
            return false
        }
    }

    /// A terminal lag close (4010, 4011, 4012), decided in a synchronous segment: the session stops
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
        case SessionClose.Code.unencodableView:
            syncLagUnencodableCloses += 1
            syncLagProfilerCounters?.addSyncLag(.init(unencodableCloses: 1))
            reason = "state view does not encode"
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

    /// Logs a failed sync plan, at most every 10 seconds: a deterministic failure fails every
    /// plan, and would otherwise log every cycle.
    private func logSyncFailureIfDue(_ error: any Error) {
        let now = ContinuousClock.now
        if let last = lastSyncFailureLog, now - last < .seconds(10) {
            return
        }
        lastSyncFailureLog = now
        logger.error("❌ Sync plan failed; nothing was committed, the next plan resends its changes", metadata: [
            "landID": .string(landID),
            "failedPlans": .string("\(syncFailedPlans)"),
            "error": .string("\(error)")
        ])
    }

    /// One full sync cycle on `state`: plan, then commit. If the plan throws, the dirty fields
    /// this cycle's `beginSync` cleared are carried into the next plan.
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

    /// The read of the legacy cycle running its phase (`withSyncState`), for its plan.
    private var legacyCycleRead: SyncOutputRead?

    /// Whether the keeper records its sync stream. Only asked with in-turn sync on, where this
    /// adapter runs on the keeper's executor; with it off nothing is recorded.
    private func keeperRecordsSyncStream() -> Bool {
        guard inTurnSyncEnabled else { return false }
        return keeper.assumeIsolated { $0.recordsSyncStream }
    }

    /// The read of an in-turn plan: the turn's own state, so its position is the keeper's now.
    private func inTurnSyncOutputRead() -> SyncOutputRead? {
        guard inTurnSyncEnabled else { return nil }
        return keeper.assumeIsolated { keeper in
            guard keeper.recordsSyncStream else { return nil }
            return SyncOutputRead(turnKind: keeper.currentSyncTurnKind, position: keeper.syncReadPosition())
        }
    }

    /// `keeper.beginSync`, located in the same keeper job when the sync stream is recorded.
    private func beginSyncLocatedIfRecording(clearDirtyFlags: Bool) async -> (State, SyncOutputRead?)? {
        guard inTurnSyncEnabled else {
            return await keeper.beginSync(clearDirtyFlags: clearDirtyFlags).map { ($0, nil) }
        }
        guard let located = await keeper.beginSyncLocated(clearDirtyFlags: clearDirtyFlags) else { return nil }
        let read = keeperRecordsSyncStream() ? SyncOutputRead(turnKind: .legacyCycle, position: located.position) : nil
        return (located.state, read)
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
        planFailedRows = []
        return plan
    }

    /// Records a committed plan's output (or a firstSync's seed) in the keeper's sync stream.
    /// Runs in the commit's synchronous segment, so commit order is stream order.
    private func recordSyncStream(_ digest: SyncOutputDigestInput, broadcastCommitted: Bool, read: SyncOutputRead) {
        let observedTickId = read.position?.observedTickId
        let sequence = read.position?.sequence ?? -1
        // A resynced player's view restarts: a clear before this plan's output, for the players
        // whose snapshot committed (a seed follows). One whose snapshot didn't encode keeps its
        // view, live and in the stream.
        for playerID in digest.resyncPlayers.filter({ digest.seeds[$0] != nil }).sorted(by: { SnapshotValue.utf8Less($0.rawValue, $1.rawValue) }) {
            recordSyncStreamClear(playerID)
        }
        if !digest.isFirstSync {
            let broadcastHash = broadcastCommitted
                ? digest.broadcastPatches.map { Self.scopeHash($0, scope: SyncOutputDigestInput.broadcastScope) }
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
                let pairs = hashed.map { ($0.key.rawValue, Self.scopeHash($0.value, scope: $0.key.rawValue)) }
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
                let unverified = digest.recipients.filter { syncStreamUnverifiedPlayers.contains($0) }
                perPlayerUnverified = unverified.isEmpty ? nil : Self.sortedIDs(unverified)
                perPlayerUncommitted = digest.uncommitted.isEmpty ? nil : Self.sortedIDs(Array(digest.uncommitted))
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
            keeper.assumeIsolated { keeper in
                keeper.recordSyncOutput(observedTickId: observedTickId) { streamIndex, index in
                    ReevaluationRecordedSyncOutput(
                        index: index,
                        turnKind: turnKind,
                        observedTickId: observedTickId,
                        streamIndex: streamIndex,
                        sequence: sequence,
                        broadcastHash: broadcastHash,
                        perPlayerHash: perPlayerHash,
                        perPlayerUnverified: perPlayerUnverified,
                        perPlayerUncommitted: perPlayerUncommitted,
                        perPlayerHashes: perPlayerHashes,
                        eventsHash: eventsHash,
                        eventsThroughSequence: eventsThroughSequence,
                        eventsNotQueued: eventsNotQueued,
                        eventsNotMerged: eventsNotMerged,
                        resetsKeyScopes: digest.resetsKeyScopes ? true : nil,
                        extractionDrops: extractionDrops,
                        encodeDropScopes: encodeDropScopes,
                        patches: patches
                    )
                }
            }
        }
        for (playerID, seed) in digest.seeds.sorted(by: { SnapshotValue.utf8Less($0.key.rawValue, $1.key.rawValue) }) {
            let rejoin = !syncStreamSeededPlayers.insert(playerID).inserted
            let viewDrops = seed.drops.sorted { $0.rawValue < $1.rawValue }
            if viewDrops.isEmpty {
                syncStreamUnverifiedPlayers.remove(playerID)
            } else {
                syncStreamUnverifiedPlayers.insert(playerID)
            }
            let viewHash = viewDrops.isEmpty ? Self.scopeHash(seed.patches, scope: playerID.rawValue) : nil
            let dropFields = Array(Set(seed.dropFields)).sorted { SnapshotValue.utf8Less($0, $1) }
            keeper.assumeIsolated { keeper in
                keeper.recordSyncMarker { streamIndex in
                    ReevaluationRecordedSyncMarker(
                        kind: .seed,
                        playerID: playerID.rawValue,
                        observedTickId: observedTickId,
                        streamIndex: streamIndex,
                        sequence: sequence,
                        rejoin: rejoin,
                        viewHash: viewHash,
                        viewDrops: viewDrops,
                        viewDropFields: dropFields.isEmpty ? nil : dropFields
                    )
                }
            }
        }
    }

    /// The canonical form of an in-turn event: its keeper sequence, type and payload. Nil when it
    /// has no sequence or its payload does not convert (the events scope is then unverifiable).
    private static func canonicalEvent(_ item: InTurnServerEvent) -> CanonicalSyncEvent? {
        guard let sequence = item.sequence,
              let payload = try? SnapshotValue.make(from: item.event.payload.base) else { return nil }
        return CanonicalSyncEvent(sequence: sequence, type: item.event.type, payload: payload)
    }

    /// Records a clear marker: the player's per-player cache and firstSync mark were dropped.
    /// `outsideTurn`: recorded after the leave's turn, outside any keeper turn (a disconnect);
    /// a tickless land then closes it as its own turn record (#327). A superseded session's
    /// clear is recorded in the join's admission, and the join's input turn closes it.
    private func recordSyncStreamClear(_ playerID: PlayerID, outsideTurn: Bool = false) {
        guard keeperRecordsSyncStream() else { return }
        syncStreamUnverifiedPlayers.remove(playerID)
        keeper.assumeIsolated { keeper in
            let sequence = keeper.syncReadPosition().sequence
            keeper.recordSyncMarker(outsideTurn: outsideTurn) { streamIndex in
                ReevaluationRecordedSyncMarker(kind: .clear, playerID: playerID.rawValue, streamIndex: streamIndex, sequence: sequence)
            }
        }
    }

    /// The canonical hash of one scope's patches. The diff never puts a path and one of its
    /// descendants in one scope; debug builds check it.
    private static func scopeHash(_ patches: [StatePatch], scope: String) -> UInt64 {
        let list = CanonicalPatchList(patches)
        assert(!list.hasPrefixPairs, "sync scope \(scope) has a path and one of its descendants")
        return list.hash
    }

    private static func sortedIDs(_ players: [PlayerID]) -> [String] {
        players.map(\.rawValue).sorted { SnapshotValue.utf8Less($0, $1) }
    }

    /// The dirty fields a plan diffs: the state's, plus those carried from failed plans.
    private func planDirtyFields(of state: State) -> Set<String> {
        let carried = rowRetryFields.isEmpty ? carriedDirtyFields : carriedDirtyFields.union(rowRetryFields)
        return carried.isEmpty ? state.getDirtyFields() : state.getDirtyFields().union(carried)
    }

    /// Whether a plan has dirty fields to diff (`planDirtyFields(of:)` is not empty).
    private func planIsDirty(_ state: State) -> Bool {
        state.isDirty() || !carriedDirtyFields.isEmpty || !rowRetryFields.isEmpty
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
    private func heldEventsWouldOverflow(_ sessionID: SessionID, adding frames: [Data]) -> Bool {
        guard let joining = joiningSessions[sessionID], !frames.isEmpty else { return false }
        let limit = heldEventsLimit
        let bytes = frames.reduce(0) { $0 + $1.count }
        return joining.heldEvents.count + frames.count > limit.count || joining.heldBytes + bytes > limit.bytes
    }

    /// Holds `frames` (encoded event frames) for the joining `sessionID`, after the ones it
    /// holds. Returns false when that goes over the bound: then the session's held events and
    /// `frames` are discarded and counted, and the caller fails the join with `eventOverflow`.
    private func holdEvents(_ frames: [Data], for sessionID: SessionID) -> Bool {
        guard !frames.isEmpty, var joining = joiningSessions[sessionID] else { return true }
        if heldEventsWouldOverflow(sessionID, adding: frames) {
            noteEventsDroppedForJoiningSessions(joining.heldEvents.count + frames.count)
            joining.heldEvents = []
            joining.heldBytes = 0
            joiningSessions[sessionID] = joining
            return false
        }
        joining.heldEvents.append(contentsOf: frames)
        joining.heldBytes += frames.reduce(0) { $0 + $1.count }
        joiningSessions[sessionID] = joining
        return true
    }

    /// A target resolution's event for a joining session: held when the session holds events
    /// (an overflow is recorded, and fails the join after the emit returns), counted as
    /// dropped otherwise.
    func holdOrDropEvent(_ frame: Data?, for sessionID: SessionID) {
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
    private func heldEventFrames(events: PendingEventManager, endingBefore end: Int) -> [SessionID: [Data]] {
        guard end > 0 else { return [:] }
        var held: [SessionID: [Data]] = [:]
        for (sessionID, joining) in joiningSessions where holdsEvents(sessionID) {
            let bodies = pendingTargetedEventBodies(
                events: events,
                for: sessionID,
                playerID: joining.playerID,
                endingBefore: end
            )
            var frames: [SyncPhaseFrame] = []
            appendEventFrames(bodies, to: sessionID, into: &frames)
            if !frames.isEmpty {
                held[sessionID] = frames.map(\.data)
            }
        }
        return held
    }

    private func logDroppedUpdatesIfDue(_ dropped: Int, reason: String?) {
        let now = ContinuousClock.now
        if let last = lastDroppedUpdatesLog, now - last < .seconds(10) {
            return
        }
        lastDroppedUpdatesLog = now
        logger.error("❌ Sync dropped updates or fields that do not encode or extract (data loss: those fields stay stale on clients until they change)", metadata: [
            "landID": .string(landID),
            "dropped": .string("\(dropped)"),
            "droppedTotal": .string("\(syncDroppedUpdates)"),
            "error": .string(reason ?? "unknown")
        ])
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
        return recipients
    }

    /// The commit of a sync phase: synchronous, in the same actor turn as its plan.
    ///
    /// Writes the staged caches and firstSync marks, removes the events the plan consumed, applies
    /// the metric and dirty-tracking updates, and enqueues the frames as one writer element. Dirty
    /// flags were cleared by the keeper when `beginSync` took the copy (#68); a committed full plan
    /// ends the carry of failed plans' dirty fields, and one that reset the key scopes ends a
    /// pending reset.
    private func commitSyncPhase(_ plan: SyncPhasePlan, isSyncCycle: Bool) {
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
        if plan.skippedJoiner && plan.encodeSkippedJoiners.isEmpty {
            noteFailedPlanForFollowUp()
        }
        // In-turn joiners that were not flipped (#69): a delayed follow-up retries them, at most
        // `syncFailedPlanFollowUpLimit` times each on a land without periodic sync. They don't
        // ask for join sync turns of their own, so a firstSync that keeps failing to encode
        // can't run full phases back to back; the join flip timeout ends such a join.
        var retriesSkippedJoiner = false
        for sessionID in plan.encodeSkippedJoiners {
            guard let skips = joiningSessions[sessionID]?.inTurn?.encodeSkips else { continue }
            joiningSessions[sessionID]?.inTurn?.encodeSkips = skips + 1
            if skips + 1 <= Self.syncFailedPlanFollowUpLimit { retriesSkippedJoiner = true }
        }
        if retriesSkippedJoiner && !keeper.hasPeriodicSync {
            startDelayedFollowUpSync()
        }
        // Before the flips end their joining: what this plan consumes for joining sessions is
        // held for those that hold events (#69), and not delivered to the others.
        let held = plan.heldEvents.flatMap { plan.heldEventsEnd == plan.consumedEvents.targeted ? $0 : nil }
            ?? heldEventFrames(events: pendingEventManager, endingBefore: plan.consumedEvents.targeted)
        var overflowed: [SessionID] = []
        for (sessionID, frames) in held where !holdEvents(frames, for: sessionID) {
            overflowed.append(sessionID)
        }
        noteEventsDroppedForJoiningSessions(targetedEventsForJoiningSessions(endingBefore: plan.consumedEvents.targeted))
        // The flips (#69), in the commit's segment: the joins end, their waiters resume. Each
        // flip's held events follow its firstSync in this element.
        var frames = plan.frames.map { sessionFrame($0.data, to: $0.sessionID) }
        var drainsToStart: [SessionID] = []
        for flip in plan.flips where joiningSessions[flip.sessionID]?.ticket == flip.ticket {
            guard let joining = joiningSessions.removeValue(forKey: flip.sessionID) else { continue }
            noteSessionJoined(flip.sessionID, playerID: joining.playerID)
            startSyncLagTracking(flip.sessionID, plan: plan)
            for data in joining.heldEvents {
                frames.append(sessionFrame(data, to: flip.sessionID))
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
            joinWaiters[flip.sessionID]?.resolve(.success(()))
        }
        if plan.droppedUpdates > 0 {
            syncDroppedUpdates += plan.droppedUpdates
            profilerCounters?.incrementSyncDroppedUpdates(by: plan.droppedUpdates)
            logDroppedUpdatesIfDue(plan.droppedUpdates, reason: plan.dropReason)
        }
        pendingEventManager.removeConsumed(
            targeted: plan.consumedEvents.targeted,
            broadcast: plan.consumedEvents.broadcast
        )
        if plan.isFullCycle {
            carriedDirtyFields.removeAll()
            lastCommitDroppedRows = !plan.droppedRows.isEmpty
        }
        if let fields = plan.rowRetryFields {
            rowRetryFields = fields
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
        // A skipped joiner got nothing and stays unsynced, its broadcast map empty: any later
        // merged broadcast frame, a broadcast-only one included, must define its keys.
        if (plan.needsBroadcastKeyReset || (plan.skippedJoiner && usesBroadcastKeyTable)) && broadcastKeysMayBeDefined {
            keyScopeResetPending = true
        }
        if plan.leavesKeyTablesAhead {
            keyScopeResetPending = true
        }
        if plan.stateUpdateCount > 0 {
            profilerCounters?.incrementStateUpdates(by: plan.stateUpdateCount)
        }
        if isSyncCycle {
            profilerCounters?.incrementSyncCycles()
        }
        applySyncLag(plan)
        enqueueFrames(frames, isSyncCycle: isSyncCycle)
        // After the whole flip element (JoinResponse, firstSync, held events) is enqueued: the
        // flipped sessions' deferred frames, each from a Task of its own, never inline here.
        for sessionID in drainsToStart {
            let drain = Task { await self.drainInbound(sessionID) }
            #if DEBUG
            inboundDrainTasksForTesting[sessionID] = drain
            #endif
        }
        // After the commit: the joins this plan's events took over the held-event bound. A full
        // plan left them out of its flips.
        for sessionID in overflowed {
            failInTurnJoin(sessionID: sessionID, reason: .eventOverflow)
        }
        if plan.countsChangeMetricsSync {
            changeMetricsSyncIndex &+= 1
        }
        if let metrics = plan.metrics {
            logChangeObjectMetrics(updates: metrics.updates, broadcastSnapshot: metrics.broadcastSnapshot)
        }
        if let log = plan.broadcastOnlyLog {
            logBroadcastSync(patchCount: log.patchCount, bytes: log.bytes, mode: log.mode)
        }
    }

    /// Plan of one full sync cycle (`syncNow`).
    ///
    /// Synchronous: nothing else runs on this adapter between reading its inputs and the commit.
    /// Reads `state` (the copy taken by `beginSync`), `recipients` and `events`; stages the cache
    /// updates in the plan; encodes every frame. `fullSnapshot` (the full-snapshot strategy)
    /// extracts `.all` and diffs against the `.empty` baseline. `resetsKeyScopes` types every
    /// recipient's updates `.firstSync`, sent even when empty (see `keyScopeResetPending`).
    /// Updates that fail to encode are re-encoded without the patches that do not encode
    /// (`encodeDroppingUnencodablePatches`); fields whose snapshot conversion throws are left out
    /// (`SyncEngine.ExtractionDrops`).
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
        resetsKeyScopes: Bool,
        droppingRows: Set<SyncRowRef>? = nil
    ) throws -> SyncPhasePlan {
        // Row addressing: a plan in which a row's value did not encode is made again once,
        // dropping those rows (`droppingRows`), before any frame is sent.
        let inputRecipients = recipients
        let inputJoiners = joiners
        let syncSeqBefore = lastSyncSeq
        var plan = makePlan()
        plan.isFullCycle = true
        let requestedKeyScopeReset = resetsKeyScopes
        let recipients = classifySyncLag(recipients, fullPlan: true, events: events, into: &plan)
        // Opcode 107: what this plan's targeted events hold for each joining session (#69). A
        // joiner they would take over the held-event bound is not flipped by this plan: the
        // commit fails it with `eventOverflow` instead, so it never flips a join it also fails.
        var joiners = joiners
        if useStateUpdateWithEvents {
            let held = heldEventFrames(events: events, endingBefore: events.targetedEventCount)
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
        let collectsChangeMetrics = enableChangeObjectMetrics || enableAutoDirtyTracking
        // One sync in `AUTO_DIRTY_SAMPLE_EVERY` is measured; the others skip the metric work.
        let shouldCollectChangeMetrics = collectsChangeMetrics
            && dirtyTrackingSampling.isSample(syncIndex: changeMetricsSyncIndex)
        plan.countsChangeMetricsSync = collectsChangeMetrics
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
        // The root fields the tables' diff visited (nil: every field).
        var tablesFields: Set<String>?
        if let broadcastTables {
            let fields = modesBesideTables(
                for: state, extractAll: extractAll, broadcastMode: requestedBroadcastMode, perPlayerMode: requestedPerPlayerMode
            ).broadcast.fields
            tablesFields = fields
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
        let extractEnd: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil

        var broadcastDiff: [StatePatch]
        if let tablesBroadcastDiff {
            broadcastDiff = tablesBroadcastDiff
        } else {
            broadcastDiff = withoutDroppedFields(
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
        if let droppingRows, let broadcastTables {
            // Every patch at or below a dropped row leaves the plan, tagged or not, and so do
            // the row's staged writes: last-sent keeps the row as clients have it.
            let before = broadcastDiff.count
            broadcastDiff.removeAll { patch in droppingRows.contains { $0.covers(patch.path) } }
            for row in droppingRows {
                broadcastTables.dropRow(path: row.rootPath, slot: row.slot, from: plan.stagedTables)
            }
            plan.droppedRows = droppingRows
            plan.droppedUpdates += before - broadcastDiff.count
            plan.digest?.encodeDropScopes.insert(SyncOutputDigestInput.broadcastScope)
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

        var metricUpdates: [StateUpdate] = []
        var pendingUpdates: [PendingSyncUpdate]
        if useStateUpdateWithEvents {
            let framesBefore = plan.frames.count
            if let broadcastUpdate = try planMergedBroadcastFrame(
                broadcastDiff: broadcastDiff,
                recipients: recipients,
                events: events,
                resetsKeyScope: resetsKeyScopes,
                into: &plan
            ), shouldCollectChangeMetrics {
                metricUpdates.append(broadcastUpdate)
            }
            // The broadcast key-scope reset this plan's resyncs caused, and its bytes (#332).
            if resetsKeyScopes && !requestedKeyScopeReset && !plan.syncLag.resyncPlayers.isEmpty {
                plan.syncLag.causedKeyScopeReset = true
                plan.syncLag.keyScopeResetBytes = plan.frames[framesBefore...].filter(\.isStateUpdate).reduce(0) { $0 + $1.data.count }
            }
            let perPlayerStart: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil
            pendingUpdates = collectPerPlayerOnlyPendingUpdates(
                recipients: recipients,
                perPlayerByPlayer: perPlayerByPlayer,
                perPlayerMode: perPlayerMode,
                baseline: baseline,
                typesFirstSync: resetsKeyScopes,
                skipping: skippedPlayers,
                staged: &plan.staged
            )
            if let perPlayerStart { perPlayerTime = ContinuousClock.now - perPlayerStart }
        } else {
            let perPlayerStart: ContinuousClock.Instant? = timed ? ContinuousClock.now : nil
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
            if let perPlayerStart { perPlayerTime = ContinuousClock.now - perPlayerStart }
        }
        pendingUpdates = withoutDroppedFields(pendingUpdates, drops: drops, baseline: baseline)
        if plan.digest != nil {
            plan.digest?.commitsPerPlayer = true
            plan.digest?.resetsKeyScopes = resetsKeyScopes
            plan.digest?.recipients = recipients.map(\.playerID).filter { !skippedPlayers.contains($0) }
            plan.digest?.broadcastPatches = broadcastDiff
            for update in pendingUpdates where plan.digest?.perPlayerPatches[update.playerID] == nil {
                plan.digest?.perPlayerPatches[update.playerID] = update.update.patchesForDroppingEncode
            }
        }
        // Row addressing (section 4 of the row addressing plan): with merged frames an unsynced
        // recipient also gets the shared frame, so its view holds the committed tables and goes
        // ahead of that frame; a combined frame's view holds this plan's tables.
        let viewsFromStagedTables = !useStateUpdateWithEvents
        for recipient in unsyncedRecipients {
            let dropsBefore = drops.count
            let viewFieldsBefore = drops.viewFields.count
            let (update, viewPatches) = planFullViewUpdate(
                state: state, recipient: recipient, staged: &plan.staged, stagedTables: &plan.stagedTables, drops: &drops,
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
                state: state, recipient: joiner.recipient, staged: &plan.staged, stagedTables: &plan.stagedTables, drops: &drops,
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
        plan.noteExtractionDrops(drops)
        if shouldCollectChangeMetrics {
            metricUpdates.append(contentsOf: pendingUpdates.map(\.update))
            // On the tables no broadcast snapshot was extracted: the metric (one sync in
            // `AUTO_DIRTY_SAMPLE_EVERY`) extracts its own, with the mode the diff used. A field
            // that throws takes the tables' last-sent value, as it takes the cache's today; its
            // drop was already noted by the diff.
            var metricSnapshot = broadcastSnapshot
            if let broadcastTables {
                var metricDrops = ExtractionDrops()
                metricSnapshot = syncEngine.extractBroadcastSnapshot(
                    from: state,
                    mode: broadcastMode,
                    drops: &metricDrops,
                    broadcastLastSent: { broadcastTables.lastSentSnapshot(of: $0) }
                )
            }
            plan.metrics = SyncPhaseMetrics(updates: metricUpdates, broadcastSnapshot: metricSnapshot)
        }
        planPerPlayerFrames(
            pendingUpdates,
            recipients: recipients,
            events: events,
            into: &plan
        )
        if !joiners.isEmpty {
            planJoinerFrames(joinerUpdates, joiners: joiners, events: events, into: &plan)
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
            putResyncSnapshotsFirst(&plan)
        }

        if rowAddressing {
            if droppingRows == nil, !planFailedRows.isEmpty {
                // Made again without the failing rows, with every key scope reset: the encodes
                // so far may have defined keys no client learns. Nothing was sent.
                let rows = planFailedRows
                lastSyncSeq = syncSeqBefore
                return try planSyncPhase(
                    state: state, recipients: inputRecipients, joiners: inputJoiners, events: events,
                    fullSnapshot: fullSnapshot, resetsKeyScopes: true, droppingRows: rows
                )
            }
            if let broadcastTables {
                // The retry set as this plan's commit leaves it.
                let slotFields = broadcastTables.slotAddressedFields
                let dropped = Set(plan.droppedRows.compactMap { slotFields[$0.rootPath] })
                let visited = tablesFields ?? Set(slotFields.values)
                var retry = rowRetryFields.union(dropped)
                retry.subtract(visited.subtracting(dropped).subtracting(drops.broadcastFields))
                if retry != rowRetryFields { plan.rowRetryFields = retry }
            }
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
        drops: inout ExtractionDrops
    ) -> StateSnapshot {
        guard let broadcastTables else {
            return syncEngine.lateJoinSnapshot(for: playerID, from: state, staged: &staged, drops: &drops)
        }
        let snapshot = syncEngine.lateJoinSnapshot(
            for: playerID,
            from: state,
            staged: &staged,
            drops: &drops,
            broadcastLastSent: { broadcastTables.lastSentSnapshot(of: $0) }
        )
        if !broadcastTables.isSeeded {
            broadcastTables.stageSeed(state, fields: nil, drops: &drops, into: &stagedTables)
        }
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
        drops: inout ExtractionDrops,
        rowsFromStagedTables: Bool
    ) -> (update: PendingSyncUpdate, viewPatches: [StatePatch]) {
        let snapshot = lateJoinSnapshot(for: recipient.playerID, from: state, staged: &staged, stagedTables: &stagedTables, drops: &drops)
        staged.perPlayer[recipient.playerID] = syncEngine.extractPerPlayerSnapshot(
            for: recipient.playerID,
            from: state,
            mode: .all,
            drops: &drops
        )
        staged.firstSyncReceived.insert(recipient.playerID)
        let patches = syncEngine.computeDiff(from: StateSnapshot(values: [:]), to: snapshot, onlyPaths: nil)
        var sent = patches
        if rowAddressing, let broadcastTables {
            sent = Self.replacingRows(
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

    /// `patches` (a view's, from empty) with the patches at or below each root path of `rows`
    /// replaced by that root's row patches, where the first of them was. A root `patches` doesn't
    /// hold stays out.
    static func replacingRows(of patches: [StatePatch], with rows: [String: [StatePatch]]) -> [StatePatch] {
        guard !rows.isEmpty else { return patches }
        func root(of path: String) -> String {
            let utf8 = path.utf8
            guard utf8.count > 1, let end = utf8.dropFirst().firstIndex(of: UInt8(ascii: "/")) else { return path }
            return String(path[..<end])
        }
        var result: [StatePatch] = []
        result.reserveCapacity(patches.count)
        var placed: Set<String> = []
        for patch in patches {
            let path = root(of: patch.path)
            guard let replacement = rows[path] else {
                result.append(patch)
                continue
            }
            if placed.insert(path).inserted {
                result.append(contentsOf: replacement)
            }
        }
        return result
    }

    /// A key scope reset's update: always sent, typed `.firstSync` so the encoder and the client
    /// reset the scope's dynamic key table; its patches are the diff against the cache.
    private func keyScopeResetUpdate(_ update: StateUpdate) -> StateUpdate {
        switch update {
        case .noChange:
            return .firstSync([])
        case .diff(let patches), .firstSync(let patches):
            return .firstSync(patches)
        }
    }

    /// opcode 107: the merged broadcast frame for every recipient, carrying the queued broadcast
    /// events. Returns the broadcast update (for the metrics), `nil` when no frame is planned.
    /// With `resetsKeyScope` it is always planned, typed `.firstSync` (broadcast key scope reset).
    /// If it fails to encode, it is re-encoded typed `.firstSync` without the patches that do not
    /// encode (broadcast key scope reset, the same frame for every recipient); if even an empty
    /// update fails, the broadcast events go as event frames without the state.
    private func planMergedBroadcastFrame(
        broadcastDiff: [StatePatch],
        recipients: [SyncPhaseRecipient],
        events: PendingEventManager,
        resetsKeyScope: Bool,
        into plan: inout SyncPhasePlan
    ) throws -> StateUpdate? {
        guard resetsKeyScope || !broadcastDiff.isEmpty || events.hasAnyEvents else {
            return nil
        }
        guard let first = recipients.first else {
            // No recipient (every member is in initial sync): drop the queued events, as before.
            // Initial-syncing players miss events of their join window even when another session
            // is a recipient; the boundary belongs at the firstSync snapshot (#69).
            plan.consumedEvents = SyncPhaseConsumedEvents(
                targeted: events.targetedEventCount,
                broadcast: events.broadcastEventCount
            )
            return nil
        }

        let broadcastUpdate: StateUpdate = resetsKeyScope
            ? .firstSync(broadcastDiff)
            : (broadcastDiff.isEmpty ? .noChange : .diff(broadcastDiff))
        let eventBodies = events.pendingBroadcastBodies()
        plan.consumedEvents.broadcast = events.broadcastEventCount
        guard let data = encodeMergedBroadcastFrameDropping(
            broadcastUpdate,
            playerID: first.playerID,
            eventBodies: eventBodies,
            into: &plan
        ) else {
            // No state frame: the broadcast cache keeps what clients have.
            plan.staged.broadcast = nil
            plan.stagedTables = SyncTableStaged()
            plan.leavesKeyTablesAhead = true
            for recipient in recipients {
                appendEventFrames(eventBodies, to: recipient.sessionID, into: &plan.frames)
            }
            return nil
        }
        for recipient in recipients {
            plan.frames.append(SyncPhaseFrame(data: data, sessionID: recipient.sessionID, isStateUpdate: true))
        }
        plan.stateUpdateCount += recipients.count
        return broadcastUpdate
    }

    /// `encodeMergedBroadcastFrame`; on failure, the update without the patches that do not encode,
    /// typed `.firstSync` (see `encodeDroppingUnencodablePatches`). `nil` if even that fails.
    private func encodeMergedBroadcastFrameDropping(
        _ update: StateUpdate,
        playerID: PlayerID,
        eventBodies: [MessagePackValue],
        into plan: inout SyncPhasePlan
    ) -> Data? {
        if !update.patchesForDroppingEncode.isEmpty {
            plan.encodesBroadcastPatches = true
        }
        do {
            return try encodeMergedBroadcastFrame(update: update, playerID: playerID, eventBodies: eventBodies)
        } catch {
            plan.dropReason = plan.dropReason ?? "broadcast frame: \(error)"
            let (data, dropped) = encodeDroppingUnencodablePatches(update.patchesForDroppingEncode) { patches in
                try self.encodeMergedBroadcastFrame(update: .firstSync(patches), playerID: playerID, eventBodies: eventBodies)
            }
            plan.droppedUpdates += dropped
            plan.digest?.encodeDropScopes.insert(SyncOutputDigestInput.broadcastScope)
            return data
        }
    }

    /// The broadcast state update merged with `eventBodies` (opcode 107), encoded once for every
    /// recipient.
    private func encodeMergedBroadcastFrame(
        update: StateUpdate,
        playerID: PlayerID,
        eventBodies: [MessagePackValue]
    ) throws -> Data {
        if let mpEncoder = stateUpdateEncoder as? OpcodeMessagePackStateUpdateEncoder {
            let updateArray = try mpEncoder.encodeToMessagePackArray(
                update: update,
                landID: landID,
                playerID: playerID,
                playerSlot: nil,
                scope: .broadcast,
                syncSeq: planSyncSeq
            )
            if let combined = buildStateUpdateWithEventBodies(
                stateUpdateArray: updateArray,
                eventBodies: eventBodies,
                allowEmptyEvents: true
            ) {
                return combined
            }
            return try pack(.array(updateArray))
        }
        let updateData = try encodeStateUpdate(
            update: update,
            playerID: playerID,
            playerSlot: nil,
            scope: .broadcast
        )
        return buildStateUpdateWithEventBodies(
            stateUpdateData: updateData,
            eventBodies: eventBodies,
            allowEmptyEvents: true
        ) ?? updateData
    }

    /// Per-player state frames in recipient order. With opcode 107 each recipient's targeted event
    /// frames come right before its per-player frame (alone when it has none), and the plan
    /// consumes the targeted events it read.
    ///
    /// When an update of a player fails to encode, that player's updates (every session's, merged
    /// by path) are re-encoded once without the patches that do not encode, typed `.firstSync`,
    /// and that one frame goes to every session of the player: the re-encode resets the player's
    /// key table, so every session's client must reset its map with it. Only the bad values are
    /// lost; before plan + commit the whole update was lost.
    /// The flipping joiners' frames, after everyone else's: per joiner its JoinResponse, then
    /// its firstSync (#69); the commit appends its held events. A firstSync that does not encode
    /// even empty leaves the joiner unmarked (`skippedJoiner`) and not flipped: it stays
    /// joining, gets no frame, keeps its held events, and the next full cycle retries its flip
    /// (bounded by the join flip timeout). Flipping it would send later targeted events before
    /// the held ones and before any state.
    private func planJoinerFrames(
        _ updates: [PendingSyncUpdate],
        joiners: [SyncPhaseJoiner],
        events: PendingEventManager,
        into plan: inout SyncPhasePlan
    ) {
        // A flipping joiner is left out of this plan's merged broadcast frame and gets a
        // per-player firstSync only, so its broadcast key map ends empty, as after
        // `planFirstSync`: the commit requests the same key scope reset (#90).
        plan.needsBroadcastKeyReset = usesBroadcastKeyTable
        let start = plan.frames.count
        planPerPlayerFrames(updates, recipients: joiners.map(\.recipient), events: events, includesEvents: false, into: &plan)
        let firstSyncFrames = Array(plan.frames[start...])
        plan.frames.removeSubrange(start...)
        for joiner in joiners {
            let sessionID = joiner.recipient.sessionID
            let own = firstSyncFrames.filter { $0.sessionID == sessionID }
            guard !own.isEmpty else {
                plan.skippedJoiner = true
                plan.encodeSkippedJoiners.append(sessionID)
                continue
            }
            plan.frames.append(SyncPhaseFrame(data: joiner.joinResponse, sessionID: sessionID))
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
    ) {
        var payloadBySession: [SessionID: Data] = [:]
        let (encoded, failures) = encodeUpdatesSerially(pendingUpdates)
        for update in encoded {
            payloadBySession[update.sessionID] = update.payload
        }
        if let firstFailure = failures.first {
            plan.dropReason = plan.dropReason ?? firstFailure.message
            var failedPlayers: [PlayerID] = []
            for failure in failures where !failedPlayers.contains(failure.playerID) {
                failedPlayers.append(failure.playerID)
            }
            for playerID in failedPlayers {
                let updates = pendingUpdates.filter { $0.playerID == playerID }
                var seenPaths = Set<String>()
                var patches: [StatePatch] = []
                for update in updates {
                    for patch in update.update.patchesForDroppingEncode where seenPaths.insert(patch.path).inserted {
                        patches.append(patch)
                    }
                }
                let playerSlot = updates.first?.playerSlot
                let (encoded, dropped) = encodeDroppingUnencodablePatches(patches) { kept in
                    try self.encodePerPlayerUpdate(.firstSync(kept), playerID: playerID, playerSlot: playerSlot)
                }
                plan.droppedUpdates += dropped
                // A resync is a replace: a snapshot missing a patch would delete that field on
                // the client (one NaN in a map removes every entry). It isn't sent; the session
                // stays as it was, and the next plan retries, up to a bound (4012).
                var data = encoded
                if data != nil, dropped > 0, plan.syncLag.resyncPlayers.contains(playerID) {
                    data = nil
                }
                if data == nil, plan.syncLag.resyncPlayers.contains(playerID) {
                    plan.syncLag.failedSnapshots.insert(playerID)
                }
                plan.digest?.noteEncodeDrop(playerID: playerID, committed: data != nil)
                if data == nil {
                    // Nothing goes to this player: drop its staged per-player cache and firstSync
                    // mark, so the next cycle diffs its per-player fields from what its client
                    // has (an unsynced player stays unmarked and gets its whole view then).
                    // Limit: the shared broadcast cache stays advanced for the other players, so
                    // with a combined (json / opcodeJsonArray) frame this player misses that
                    // cycle's broadcast changes until they change again, as before plan + commit.
                    // Only the opcode 107 merged broadcast frame unstages the broadcast cache.
                    plan.staged.perPlayer.removeValue(forKey: playerID)
                    plan.staged.firstSyncReceived.remove(playerID)
                    plan.leavesKeyTablesAhead = true
                }
                for recipient in recipients where recipient.playerID == playerID {
                    payloadBySession[recipient.sessionID] = data
                }
            }
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
                appendEventFrames(eventBodies, to: recipient.sessionID, into: &plan.frames)
            }
            if let payload = payloadBySession[recipient.sessionID] {
                plan.frames.append(SyncPhaseFrame(
                    data: payload, sessionID: recipient.sessionID, isStateUpdate: true,
                    isResyncSnapshot: plan.syncLag.resyncs[recipient.sessionID] != nil
                ))
                plan.stateUpdateCount += 1
            }
        }
    }

    private func computeSyncModes(
        for state: State,
        extractAll: Bool
    ) -> (broadcastMode: SnapshotMode, perPlayerMode: SnapshotMode) {
        if extractAll {
            return (.all, .all)
        }

        if enableDirtyTracking && planIsDirty(state) {
            let dirtyFields = planDirtyFields(of: state)
            let syncFields = state.getSyncFields()
            let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
            let perPlayerFieldNames = Set(syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }.map { $0.name })

            let broadcastFields = dirtyFields.intersection(broadcastFieldNames)
            let perPlayerFields = dirtyFields.intersection(perPlayerFieldNames)
            let broadcastMode: SnapshotMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
            let perPlayerMode: SnapshotMode = perPlayerFields.isEmpty ? .all : .dirtyTracking(perPlayerFields)
            return (broadcastMode, perPlayerMode)
        }

        return (.all, .all)
    }

    /// The modes today's extraction would use, for the broadcast diff on the tables and the
    /// per-player extraction beside it: the one-pass extraction's single mode for both, or the
    /// separate ones.
    private func modesBesideTables(
        for state: State,
        extractAll: Bool,
        broadcastMode: SnapshotMode,
        perPlayerMode: SnapshotMode
    ) -> (broadcast: SnapshotMode, perPlayer: SnapshotMode) {
        guard useSnapshotForSync else { return (broadcastMode, perPlayerMode) }
        let fullMode: SnapshotMode = (!extractAll && enableDirtyTracking && planIsDirty(state))
            ? .dirtyTracking(planDirtyFields(of: state))
            : .all
        return (fullMode, fullMode)
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
                update = keyScopeResetUpdate(update)
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
                update = keyScopeResetUpdate(update)
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
        let (updateType, patchCount) = describeUpdate(update)
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

    /// Sync only broadcast changes to all connected players.
    ///
    /// Used when state changes only affect broadcast fields (e.g., player leaving).
    /// This is more efficient than `syncNow()` because:
    /// - Uses dirty tracking to only compare changed broadcast fields
    /// - Only computes broadcast diff once (updates shared broadcast cache)
    /// - Sends same update to all players (no per-player diff needed)
    /// - Per-player cache for leaving player is cleared separately (in onDisconnect)
    ///
    /// - Note: This method assumes the state has been modified and marked as dirty.
    ///   The caller (e.g., OnLeave handler) should have already removed the player's data
    ///   from broadcast fields, which will trigger `isDirty()`.
    ///
    /// TODO: Future optimizations:
    /// - Batch multiple broadcast-only syncs into a single operation
    /// - Debounce rapid broadcast changes to reduce sync frequency
    /// - Consider allowing concurrent broadcast-only syncs (read-only operation)
    func _syncBroadcastOnlyImpl() async {
        // While frozen, the settle cycle is the only sync; defer this one to resume.
        if debugDeferSyncIfFrozen(broadcastOnly: true) { return }

        // Never clears dirty flags: this cycle does not diff per-player fields. The next syncNow
        // re-diffs broadcast fields against the updated cache (extra work, no extra patches).
        // syncNow skips empty lands before beginSync, so in an empty land flags (including removed
        // dictionary keys) accumulate until a syncNow runs with members: memory and work, not correctness.
        let needsFollowUp = await withSyncState(
            clearDirtyFlags: false,
            broadcastOnly: true,
            skipLogMessage: "⏭️ Broadcast-only sync skipped: another sync operation is in progress",
            errorLogMessage: "❌ Failed to sync broadcast-only"
        ) { state in
            // A pending key scope reset or carried dirty fields need every recipient and every
            // field: run a full cycle (it keeps the flags, so the next cycle re-diffs them: extra
            // work, no extra patches).
            // A resync due needs a full plan too (#332): decided here, once, at the same `now`
            // the broadcast-only plan would classify with.
            // Row addressing drops rows and orders views in the full plan only.
            let lagNow = syncLagNow()
            if (rowAddressing || keyScopeResetPending || !carriedDirtyFields.isEmpty || syncLagFullPlanRequested || syncLagResyncDue(at: lagNow)) && !membershipCoordinator.isEmpty {
                try runFullSyncPhase(state: state, read: legacyCycleRead)
                return
            }
            try runSyncPhase(read: legacyCycleRead) {
                try planBroadcastOnlySyncPhase(
                    state: state,
                    recipients: syncPhaseRecipients(),
                    lagNow: lagNow,
                    hasMembers: !membershipCoordinator.isEmpty,
                    events: pendingEventManager,
                    fullSnapshot: syncStrategy == .fullSnapshot
                )
            }
        }
        if needsFollowUp {
            startFollowUpSync()
        }
    }

    /// Plan of a broadcast-only cycle: the broadcast diff for every recipient and, with opcode
    /// 107, the queued events. Synchronous, like `planSyncPhase`.
    ///
    /// Even without members the diff runs, so the broadcast cache reflects the current state when
    /// players reconnect. Without members or without changes nothing is sent and queued events
    /// stay queued.
    private func planBroadcastOnlySyncPhase(
        state: State,
        recipients: [SyncPhaseRecipient],
        lagNow: ContinuousClock.Instant,
        hasMembers: Bool,
        events: PendingEventManager,
        fullSnapshot: Bool
    ) throws -> SyncPhasePlan {
        var plan = makePlan()
        let recipients = classifySyncLag(recipients, fullPlan: false, now: lagNow, events: events, into: &plan)
        var drops = ExtractionDrops()
        let (broadcastDiff, broadcastMode) = extractAndComputeBroadcastDiff(
            state: state,
            fullSnapshot: fullSnapshot,
            staged: &plan.staged,
            stagedTables: &plan.stagedTables,
            drops: &drops
        )
        plan.noteExtractionDrops(drops)
        plan.digest?.broadcastPatches = broadcastDiff
        plan.digest?.noteDrops(drops)

        guard hasMembers && !broadcastDiff.isEmpty else {
            logBroadcastCacheUpdate(patchCount: broadcastDiff.count, mode: broadcastMode, hasPlayers: hasMembers)
            try syncPlanFaultForTesting?()
            return plan
        }

        let update = StateUpdate.diff(broadcastDiff)
        let updateSize: Int?
        if useStateUpdateWithEvents {
            updateSize = try planBroadcastOnlyMergedFrame(update: update, recipients: recipients, events: events, into: &plan)
            plan.consumedEvents.targeted = events.targetedEventCount
            if events.hasTargetedEvents {
                for recipient in recipients {
                    let eventBodies = pendingTargetedEventBodies(
                        events: events,
                        for: recipient.sessionID,
                        playerID: recipient.playerID,
                        endingBefore: plan.consumedEvents.targeted
                    )
                    appendEventFrames(eventBodies, to: recipient.sessionID, into: &plan.frames)
                }
            }
        } else {
            updateSize = planBroadcastOnlySeparateFrames(update: update, recipients: recipients, into: &plan)
        }
        plan.broadcastOnlyLog = SyncPhaseBroadcastLog(patchCount: broadcastDiff.count, bytes: updateSize, mode: broadcastMode)

        try syncPlanFaultForTesting?()
        return plan
    }

    /// Extract broadcast snapshot and compute diff.
    ///
    /// Determines snapshot mode based on dirty tracking, extracts broadcast snapshot,
    /// and computes diff against cached broadcast state.
    ///
    /// - Parameters:
    ///   - state: Current state to extract from
    ///   - fullSnapshot: Extract `.all` and diff against the `.empty` baseline.
    ///   - staged: Receives the broadcast cache update.
    /// - Returns: Tuple of (diff patches, snapshot mode used)
    private func extractAndComputeBroadcastDiff(
        state: State,
        fullSnapshot: Bool,
        staged: inout SyncEngine.StagedCaches,
        stagedTables: inout SyncTableStaged,
        drops: inout ExtractionDrops
    ) -> (diff: [StatePatch], mode: SnapshotMode) {
        // Determine snapshot mode based on dirty tracking
        let broadcastMode: SnapshotMode
        if !fullSnapshot, enableDirtyTracking && planIsDirty(state) {
            let dirtyFields = planDirtyFields(of: state)
            let syncFields = state.getSyncFields()
            let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
            let broadcastFields = dirtyFields.intersection(broadcastFieldNames)

            // Only extract and compare dirty broadcast fields
            broadcastMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
        } else {
            // Full-snapshot strategy, dirty tracking disabled, or state not dirty: always use .all mode
            broadcastMode = .all
        }

        if let broadcastTables {
            return (broadcastTables.planDiff(state, fields: broadcastMode.fields, drops: &drops, into: &stagedTables), broadcastMode)
        }

        // Extract broadcast snapshot (only dirty fields if using dirty tracking)
        let broadcastSnapshot = syncEngine.extractBroadcastSnapshot(from: state, mode: broadcastMode, drops: &drops)

        // Compute broadcast diff (only compares dirty fields); under the full-snapshot strategy
        // without the dropped fields (`withoutDroppedFields`).
        // This updates the shared broadcast cache
        // IMPORTANT: We always compute the diff to update the cache, even if no players are connected
        // This ensures the cache reflects the current state when players reconnect
        let broadcastDiff = syncEngine.computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            onlyPaths: nil,
            mode: broadcastMode,
            baseline: fullSnapshot ? .empty : .cached,
            staged: &staged
        )

        return (withoutDroppedFields(broadcastDiff, dropped: drops.broadcastFields, baseline: fullSnapshot ? .empty : .cached), broadcastMode)
    }

    /// Under the `.empty` baseline (full-snapshot strategy), `patches` without those of the
    /// fields the extraction dropped in their scope (`dropped`). A dropped field holds its cached
    /// value, which keeps the `.empty` diff from deleting it but would otherwise be a real `.set`
    /// of an older value (a client that already has a newer one, e.g. a joiner's firstSync, would
    /// roll back). Against the `.cached` baseline the cached value yields no patch, so nothing is
    /// filtered.
    private func withoutDroppedFields(
        _ patches: [StatePatch],
        dropped: Set<String>,
        baseline: SyncEngine.DiffBaseline
    ) -> [StatePatch] {
        guard case .empty = baseline, !dropped.isEmpty else { return patches }
        return patches.filter { patch in
            let field = patch.path.split(separator: "/").first.map(String.init) ?? ""
            return !dropped.contains(field)
        }
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
                update = .firstSync(withoutDroppedFields(patches, dropped: dropped, baseline: baseline))
            case .diff(let patches):
                let kept = withoutDroppedFields(patches, dropped: dropped, baseline: baseline)
                guard !kept.isEmpty else { return nil }
                update = .diff(kept)
            }
            return makePendingSyncUpdate(sessionID: pending.sessionID, playerID: pending.playerID, update: update)
        }
    }

    /// opcode 107, broadcast-only: the update merged with the queued broadcast events, one frame
    /// for every recipient. Without a recipient the queued events are dropped, as before (#69).
    /// Returns the frame size (for logging).
    private func planBroadcastOnlyMergedFrame(
        update: StateUpdate,
        recipients: [SyncPhaseRecipient],
        events: PendingEventManager,
        into plan: inout SyncPhasePlan
    ) throws -> Int? {
        guard let first = recipients.first else {
            plan.consumedEvents = SyncPhaseConsumedEvents(
                targeted: events.targetedEventCount,
                broadcast: events.broadcastEventCount
            )
            return nil
        }
        let eventBodies = events.pendingBroadcastBodies()
        plan.consumedEvents.broadcast = events.broadcastEventCount
        guard let data = encodeMergedBroadcastFrameDropping(
            update,
            playerID: first.playerID,
            eventBodies: eventBodies,
            into: &plan
        ) else {
            // No state frame: the broadcast cache keeps what clients have.
            plan.staged.broadcast = nil
            plan.stagedTables = SyncTableStaged()
            plan.leavesKeyTablesAhead = true
            for recipient in recipients {
                appendEventFrames(eventBodies, to: recipient.sessionID, into: &plan.frames)
            }
            return nil
        }
        for recipient in recipients {
            plan.frames.append(SyncPhaseFrame(data: data, sessionID: recipient.sessionID, isStateUpdate: true))
        }
        plan.stateUpdateCount += recipients.count
        return data.count
    }

    /// json / opcodeJsonArray, broadcast-only: the update encoded per player (no event merging),
    /// the same frame for each of its sessions. If it fails to encode for a player, it is
    /// re-encoded for that player typed `.firstSync` without the patches that do not encode (see
    /// `encodeDroppingUnencodablePatches`). Returns the size of the last encoded frame (for
    /// logging).
    private func planBroadcastOnlySeparateFrames(
        update: StateUpdate,
        recipients: [SyncPhaseRecipient],
        into plan: inout SyncPhasePlan
    ) -> Int? {
        var lastUpdateSize: Int?
        var dataByPlayer: [PlayerID: Data?] = [:]
        for recipient in recipients {
            let updateData: Data?
            if let cached = dataByPlayer[recipient.playerID] {
                updateData = cached
            } else {
                let playerID = recipient.playerID
                let playerSlot = getPlayerSlot(for: playerID)
                do {
                    updateData = try encodePerPlayerUpdate(update, playerID: playerID, playerSlot: playerSlot)
                } catch {
                    plan.dropReason = plan.dropReason ?? "\(error)"
                    let (data, dropped) = encodeDroppingUnencodablePatches(update.patchesForDroppingEncode) { kept in
                        try self.encodePerPlayerUpdate(.firstSync(kept), playerID: playerID, playerSlot: playerSlot)
                    }
                    plan.droppedUpdates += dropped
                    plan.digest?.encodeDropScopes.insert(playerID.rawValue)
                    if data == nil {
                        plan.leavesKeyTablesAhead = true
                    }
                    updateData = data
                }
                dataByPlayer[playerID] = updateData
            }
            guard let updateData else { continue }
            lastUpdateSize = updateData.count

            // Debug: Log first few bytes to verify encoding format
            if logger.logLevel <= .trace,
               let preview = String(data: updateData.prefix(100), encoding: .utf8)
            {
                logger.trace("📤 Encoded update preview", metadata: [
                    "playerID": .string(recipient.playerID.rawValue),
                    "bytes": .string("\(updateData.count)"),
                    "preview": .string(preview)
                ])
            }

            plan.frames.append(SyncPhaseFrame(data: updateData, sessionID: recipient.sessionID, isStateUpdate: true))
            plan.stateUpdateCount += 1
        }
        return lastUpdateSize
    }

    /// Log broadcast cache update (when no players or no changes).
    private func logBroadcastCacheUpdate(patchCount: Int, mode: SnapshotMode, hasPlayers: Bool) {
        if !hasPlayers && logger.logLevel <= .debug {
            logger.debug("📤 Broadcast cache updated (no players connected)", metadata: [
                "patches": .string("\(patchCount)"),
                "mode": .string("\(mode)")
            ])
        }
    }
    
    /// Log successful broadcast sync.
    private func logBroadcastSync(patchCount: Int, bytes: Int?, mode: SnapshotMode) {
        if logger.logLevel <= .debug {
            logger.debug("📤 Broadcast-only sync", metadata: [
                "players": .string("\(membershipCoordinator.joinedCount())"),
                "patches": .string("\(patchCount)"),
                "bytes": .string("\(bytes ?? 0)"),
                "mode": .string("\(mode)")
            ])
        }
    }

    // MARK: - Encoding Support

    /// Pending sync update before encoding
    private struct PendingSyncUpdate: Sendable {
        let sessionID: SessionID
        let playerID: PlayerID
        let playerSlot: Int32?
        let update: StateUpdate
        let updateType: String
        let patchCount: Int
    }

    /// Encoded sync update ready to send
    private struct EncodedSyncUpdate: Sendable {
        let sessionID: SessionID
        let playerID: PlayerID
        let updateType: String
        let patchCount: Int
        let payload: Data
    }

    /// Describe update type and patch count
    private func describeUpdate(_ update: StateUpdate) -> (String, Int) {
        switch update {
        case .noChange:
            return ("noChange", 0)
        case .firstSync(let patches):
            return ("firstSync", patches.count)
        case .diff(let patches):
            return ("diff", patches.count)
        }
    }
    
    private func extractPatches(from update: StateUpdate) -> [StatePatch] {
        switch update {
        case .noChange:
            return []
        case .firstSync(let patches), .diff(let patches):
            return patches
        }
    }
    
    private func isLikelyCollectionObject(_ object: [String: SnapshotValue]) -> Bool {
        if object.isEmpty {
            return false
        }
        var nestedCount = 0
        for value in object.values {
            switch value {
            case .object, .array:
                nestedCount += 1
            default:
                break
            }
        }
        return nestedCount > 0 && nestedCount * 2 >= object.count
    }
    
    private func estimateTotalSyncObjects(from snapshot: StateSnapshot) -> Int {
        var total = 0
        for value in snapshot.values.values {
            switch value {
            case .object(let object):
                if isLikelyCollectionObject(object) {
                    total += object.count
                } else {
                    total += 1
                }
            default:
                total += 1
            }
        }
        return max(0, total)
    }
    
    private func objectKeyFromPatchPath(_ path: String, snapshot: StateSnapshot) -> String? {
        let segments = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let top = segments.first else { return nil }
        
        guard let topValue = snapshot.values[top] else {
            return "/\(top)"
        }
        
        if case .object(let object) = topValue,
           segments.count >= 2 {
            let second = segments[1]
            if let child = object[second] {
                switch child {
                case .object, .array:
                    return "/\(top)/\(second)"
                default:
                    break
                }
            }
            if isLikelyCollectionObject(object) {
                return "/\(top)/\(second)"
            }
        }
        
        return "/\(top)"
    }
    
    private func logChangeObjectMetrics(
        updates: [StateUpdate],
        broadcastSnapshot: StateSnapshot
    ) {
        // Use calculator for pure computation (no await, easily testable)
        let result = dirtyTrackingMetrics.calculate(
            updates: updates,
            broadcastSnapshot: broadcastSnapshot,
            state: &dirtyTrackingMetricsState,
            extractPatches: extractPatches,
            estimateTotalObjects: estimateTotalSyncObjects,
            objectKeyFromPath: objectKeyFromPatchPath
        )
        
        // Handle side effects (auto-switch dirty tracking, logging)
        maybeAutoSwitchDirtyTracking(changeRateEma: result.changeRateEma)
        
        if enableChangeObjectMetrics, Int(dirtyTrackingMetricsState.syncCount % UInt64(changeObjectMetricsLogEvery)) == 0 {
            logger.info("📊 Change-object metrics", metadata: [
                "landID": .string(landID),
                "changedObjects": .string("\(result.changedObjects)"),
                "unchangedObjects": .string("\(result.unchangedObjects)"),
                "estimatedTotalObjects": .string("\(result.estimatedTotalObjects)"),
                "changeRate": .string(String(format: "%.4f", result.changeRate)),
                "changeRateEma": .string(String(format: "%.4f", result.changeRateEma)),
                "dirtyTracking": .string(enableDirtyTracking ? "on" : "off"),
                "samples": .string("\(dirtyTrackingMetricsState.syncCount)")
            ])
        }
    }
    
    private func maybeAutoSwitchDirtyTracking(changeRateEma: Double) {
        guard enableAutoDirtyTracking else { return }
        
        if enableDirtyTracking {
            autoDirtyOnCandidateCount = 0
            if changeRateEma >= autoDirtyOffThreshold {
                autoDirtyOffCandidateCount += 1
                if autoDirtyOffCandidateCount >= autoDirtyRequiredConsecutiveSamples {
                    enableDirtyTracking = false
                    autoDirtyOffCandidateCount = 0
                    logger.notice("🔄 Auto-switch dirty tracking", metadata: [
                        "landID": .string(landID),
                        "newMode": .string("off"),
                        "changeRateEma": .string(String(format: "%.4f", changeRateEma)),
                        "offThreshold": .string(String(format: "%.4f", autoDirtyOffThreshold)),
                        "requiredSamples": .string("\(autoDirtyRequiredConsecutiveSamples)")
                    ])
                }
            } else {
                autoDirtyOffCandidateCount = 0
            }
        } else {
            autoDirtyOffCandidateCount = 0
            if changeRateEma <= autoDirtyOnThreshold {
                autoDirtyOnCandidateCount += 1
                if autoDirtyOnCandidateCount >= autoDirtyRequiredConsecutiveSamples {
                    enableDirtyTracking = true
                    autoDirtyOnCandidateCount = 0
                    logger.notice("🔄 Auto-switch dirty tracking", metadata: [
                        "landID": .string(landID),
                        "newMode": .string("on"),
                        "changeRateEma": .string(String(format: "%.4f", changeRateEma)),
                        "onThreshold": .string(String(format: "%.4f", autoDirtyOnThreshold)),
                        "requiredSamples": .string("\(autoDirtyRequiredConsecutiveSamples)")
                    ])
                }
            } else {
                autoDirtyOnCandidateCount = 0
            }
        }
    }

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
                    message: "\(error)"
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
        if let syncSeq = planSyncSeq {
            guard let sequenced = sequencedStateUpdateEncoder else {
                preconditionFailure("a sync sequence planned with an encoder that can't carry it")
            }
            return try sequenced.encode(
                update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: .perPlayer,
                syncSeq: syncSeq, resync: planResyncPlayers.contains(playerID)
            )
        }
        return try stateUpdateEncoder.encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot)
    }

    /// Re-encode after an encode failure: `encode` (which types the patches `.firstSync`) is tried
    /// with each patch alone, then with every patch that encoded alone. If that fails too, an
    /// empty update is encoded, which still resets the key scope on both sides. Returns the frame
    /// (`nil` only if even the empty update fails) and how many patches were dropped (at least one
    /// when the frame is `nil`).
    ///
    /// The `.firstSync` type matters: the failed encode and the trials may have allocated key
    /// slots the client never learned, and the final encode resets the scope's key table (the
    /// client resets its map) and defines every key it uses. Clients merge a firstSync's patches
    /// like a diff. A patch is dropped whole, so healthy values inside it (siblings in the same
    /// object or array patch) go with it; the field reaches clients again on its next change.
    private func encodeDroppingUnencodablePatches(
        _ patches: [StatePatch],
        encode: ([StatePatch]) throws -> Data
    ) -> (Data?, dropped: Int) {
        // A loop, not a closure: Swift 6.2's region check rejects `encode` sent into an
        // actor-isolated closure that also touches `self`.
        var kept: [StatePatch] = []
        for patch in patches {
            do {
                _ = try encode([patch])
                kept.append(patch)
            } catch StateUpdateEncodingError.pathNotInSchema {
                unmappedPathCounter.recordDroppedPatch()
            } catch {
                // Row addressing: the plan drops the patch's whole row and is made again.
                if rowAddressing, let row = SyncRowRef(patch) { planFailedRows.insert(row) }
                continue
            }
        }
        if let data = try? encode(kept) {
            return (data, patches.count - kept.count)
        }
        if let data = try? encode([]) {
            return (data, patches.count)
        }
        return (nil, max(1, patches.count))
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
        let state: State
        var read: SyncOutputRead?
        if inTurnSyncEnabled {
            // One keeper job for the state and where it was read (`currentStateLocated`).
            let located = await keeper.currentStateLocated()
            state = located.state
            read = keeperRecordsSyncStream() ? SyncOutputRead(turnKind: .legacyCycle, position: located.position) : nil
        } else {
            state = await keeper.currentState()
        }
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
        do {
            try runSyncPhase(isSyncCycle: false, read: read) {
                try planFirstSync(state: state, playerID: playerID, sessionID: sessionID)
            }
        } catch {
            logger.error("❌ Failed to sync initial state", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
            // The next full cycle gives the player its whole view; without periodic sync, start it.
            noteFailedPlanForFollowUp()
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
        let snapshot = lateJoinSnapshot(for: playerID, from: state, staged: &plan.staged, stagedTables: &plan.stagedTables, drops: &drops)
        plan.noteExtractionDrops(drops)

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
            plan.dropReason = "\(error)"
            let (data, dropped) = encodeDroppingUnencodablePatches(patches) { kept in
                try self.encodePerPlayerUpdate(.firstSync(kept), playerID: playerID, playerSlot: playerSlot)
            }
            guard let data else {
                // Not even an empty firstSync encodes: skip the joiner without marking it (and
                // without its staged caches), so the next full cycle's from-empty path retries it.
                var skipped = SyncPhasePlan()
                skipped.droppedUpdates = dropped
                skipped.dropReason = "\(error)"
                skipped.skippedJoiner = true
                return skipped
            }
            plan.droppedUpdates += dropped
            plan.digest?.noteEncodeDrop(playerID: playerID, committed: true)
            updateData = data
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

        plan.frames = [SyncPhaseFrame(data: updateData, sessionID: sessionID, isStateUpdate: true)]
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
            let response: AnyCodable
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

            sendActionResponse(
                requestID: requestID,
                actionType: typeIdentifier,
                response: response,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            )
        } catch {
            handleActionError(
                error: error,
                requestID: requestID,
                envelope: envelope,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            )
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
            let outcome: Result<AnyCodable, any Error>
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
        outcome: Result<AnyCodable, any Error>,
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
            sendActionResponse(
                requestID: requestID,
                actionType: envelope.typeIdentifier,
                response: response,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            )
        case .failure(let error):
            handleActionError(
                error: error,
                requestID: requestID,
                envelope: envelope,
                playerID: playerID,
                sessionID: sessionID,
                ticket: ticket
            )
        }
    }

    private func noteActionResponseFinished() {
        actionResponsesFinished += 1
        let ready = actionResponsesFinishedWaiters.filter { $0.count <= actionResponsesFinished }
        actionResponsesFinishedWaiters.removeAll { $0.count <= actionResponsesFinished }
        ready.forEach { $0.continuation.resume() }
    }

    /// Tests only: returns once `count` pending answers have finished (sent or dropped).
    func waitForActionResponsesFinishedForTesting(_ count: Int) async {
        guard actionResponsesFinished < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            actionResponsesFinishedWaiters.append((count, continuation))
        }
    }

    /// Tests only: the action response tasks still tracked, over all sessions.
    func actionResponseTaskCountForTesting() -> Int {
        actionResponseTasks.values.reduce(0) { $0 + $1.count }
    }

    /// Send successful action response to client, if `ticket` is still current (checked in
    /// the same segment as the enqueue).
    private func sendActionResponse(
        requestID: String,
        actionType: String,
        response: AnyCodable,
        playerID: PlayerID,
        sessionID: SessionID,
        ticket: Ticket<SessionID>
    ) {
        do {
            let actionResponse = TransportMessage.actionResponse(
                requestID: requestID,
                response: response
            )
            let responseData = try messageEncoder.encode(actionResponse)

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
                enqueueOutbound(responseData, to: sessionID)
            }
            if sent == nil { droppedStaleActionAnswer(requestID: requestID, sessionID: sessionID) }
        } catch {
            logger.error("❌ Failed to send action response", metadata: [
                "requestID": .string(requestID),
                "actionType": .string(actionType),
                "error": .string("\(error)")
            ])
        }
    }
    
    /// Handle action processing error and send error response, if `ticket` is still current
    /// (checked in the same segment as the enqueue).
    private func handleActionError(
        error: Error,
        requestID: String,
        envelope: ActionEnvelope,
        playerID: PlayerID,
        sessionID: SessionID,
        ticket: Ticket<SessionID>
    ) {
        profilerCounters?.incrementErrors()
        logger.error("❌ Failed to handle action", metadata: [
            "requestID": .string(requestID),
            "actionType": .string(envelope.typeIdentifier),
            "playerID": .string(playerID.rawValue),
            "error": .string("\(error)")
        ])

        do {
            let (errorCode, errorMessage) = mapActionError(error, actionType: envelope.typeIdentifier)
            let errorPayload = ErrorPayload(
                code: errorCode,
                message: errorMessage,
                details: [
                    "requestID": AnyCodable(requestID),
                    "actionType": AnyCodable(envelope.typeIdentifier)
                ]
            )
            let errorResponse = TransportMessage.error(errorPayload)
            let errorData = try messageEncoder.encode(errorResponse)
            let sent: Void? = actionResponseTickets.ifCurrent(ticket) { _ in
                enqueueOutbound(errorData, to: sessionID)
            }
            if sent == nil { droppedStaleActionAnswer(requestID: requestID, sessionID: sessionID) }
        } catch {
            logger.error("❌ Failed to send error response", metadata: [
                "requestID": .string(requestID),
                "error": .string("\(error)")
            ])
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

    /// Map action error to error code and message.
    private func mapActionError(_ error: Error, actionType: String) -> (code: ErrorCode, message: String) {
        if let landError = error as? LandError {
            switch landError {
            case .actionNotRegistered:
                return (.actionNotRegistered, "Action not registered: \(actionType)")
            default:
                return (.actionHandlerError, "\(error)")
            }
        } else {
            return (.actionHandlerError, "\(error)")
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

        if let missing = Self.missingStateUpdateFeatures(required: stateUpdateFeatures, metadata: metadata) {
            logger.warning("Join request without required state-update features: missing=\(missing)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinStateUpdateFeatureMissing,
                message: Self.missingFeaturesMessage(missing),
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
            let (errorCode, errorMessage) = mapJoinFailure(error)
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

    private func mapJoinFailure(_ error: Error) -> (ErrorCode, String) {
        if error.localizedDescription.localizedCaseInsensitiveContains("full") {
            return (.joinRoomFull, "Room is full")
        }
        return (.joinDenied, "\(error)")
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
            var errorDetails = details ?? [:]
            errorDetails["requestID"] = AnyCodable(requestID)
            errorDetails["landID"] = AnyCodable(landID)

            let errorPayload = ErrorPayload(code: code, message: message, details: errorDetails)
            let errorResponse = TransportMessage.error(errorPayload)
            let errorData = try messageEncoder.encode(errorResponse)
            enqueueOutbound(errorData, to: sessionID)

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
            enqueueOutbound(responseData, to: sessionID)

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
    
    // MARK: - MessagePack Helper Functions
    
    private func messagePackValueToJSON(_ value: SwiftStateTreeMessagePack.MessagePackValue) throws -> Any {
        switch value {
        case .nil: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .uint(let v): return Int(v)
        case .float(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .binary(let data): return data.base64EncodedString()
        case .array(let arr): return try arr.map { try messagePackValueToJSON($0) }
        case .map(let map): return try messagePackMapToJSON(map)
        case .extended: throw TransportMessageDecodingError.invalidFormat("Extended MessagePack type not supported")
        }
    }
    
    private func messagePackMapToJSON(_ map: [SwiftStateTreeMessagePack.MessagePackValue: SwiftStateTreeMessagePack.MessagePackValue]) throws -> [String: Any] {
        var dict: [String: Any] = [:]
        for (key, value) in map {
            guard case .string(let keyString) = key else {
                throw TransportMessageDecodingError.invalidFormat("Non-string key in MessagePack map")
            }
            dict[keyString] = try messagePackValueToJSON(value)
        }
        return dict
    }
}

// MARK: - Debug Freeze

/// Debug freeze and projection, used by E2E state convergence checks.
///
/// A freeze pauses the land (no tick or sync body starts, tickless inputs are held), waits for
/// in-flight work to finish, then runs one settle sync cycle. The projection is computed from
/// the state copy that settle cycle synced, so every client that applied the settle frames can
/// be compared with it. While frozen, `syncNow` and `syncBroadcastOnly` are deferred to resume.
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
    ///   auto-resume) before its settle finished.
    public func debugFreeze() async throws -> DebugFreezeResponse {
        if debugFreezeState.count == 0 {
            debugFreezeState.generation &+= 1
            debugFreezeState.token = UUID().uuidString
            debugFreezeState.settled = nil
            let generation = debugFreezeState.generation
            debugFreezeState.settleTask = Task { try await self.debugSettle(generation: generation) }
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
        debugFreezeState.settled = settled
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
    func debugDeferSyncIfFrozen(broadcastOnly: Bool) -> Bool {
        guard debugFreezeState.count > 0 else { return false }
        if broadcastOnly {
            debugFreezeState.deferredBroadcastOnly = true
        } else {
            debugFreezeState.deferredSyncNow = true
        }
        return true
    }

    private func debugIsCurrent(_ generation: UInt64) -> Bool {
        debugFreezeState.generation == generation && debugFreezeState.count > 0
    }

    /// Pause and drain the keeper, then run one full sync cycle that `beginSync` accepted.
    /// One deadline covers the drain and the wait for `beginSync`.
    private func debugSettle(generation: UInt64) async throws -> DebugFreezeState<State>.Settled {
        let deadline = ContinuousClock.now + debugFreezeState.settleDeadline
        let drained = await keeper.debugFreeze(generation: generation, timeout: debugFreezeState.settleDeadline)
        guard debugIsCurrent(generation) else { throw DebugFreezeError.released }
        guard drained else { throw DebugFreezeError.settleTimedOut }

        // A sync cycle may still be running (started before the freeze); `beginSync` rejects
        // concurrent cycles, so retry until it accepts.
        while true {
            // Not skipped for back-pressure: wait until earlier cycles' frames left the writer,
            // so the settle frames are not queued behind them.
            if hasPendingStateElement {
                guard ContinuousClock.now < deadline else { throw DebugFreezeError.settleTimedOut }
                try await safeTaskSleep(for: .milliseconds(2))
                guard debugIsCurrent(generation) else { throw DebugFreezeError.released }
                continue
            }
            // Read before the copy is taken: a join or leave from here on is not in the copy
            // and must show up as `membershipChanged`.
            let membershipEpoch = membershipCoordinator.membershipEpoch
            // An empty land has nothing to diff: take the copy without clearing dirty flags.
            let hasMembers = !membershipCoordinator.isEmpty
            if let (state, read) = await beginSyncLocatedIfRecording(clearDirtyFlags: enableDirtyTracking && hasMembers) {
                do {
                    if hasMembers {
                        try runFullSyncPhase(state: state, read: read)
                    }
                } catch {
                    await keeper.endSync()
                    throw error
                }
                await holds.at(.cycleBeforeEndSync)
                await keeper.endSync()
                let tickId = await keeper.debugLastCommittedTickId()
                // Checked after the last await, so a release during the cycle is never published.
                guard debugIsCurrent(generation) else { throw DebugFreezeError.released }
                // As in `withSyncState`: events kept by this cycle need a follow-up when no
                // periodic sync will deliver them. Syncs are frozen, so it runs on resume.
                if pendingEventManager.hasAnyEvents && !keeper.hasPeriodicSync {
                    debugFreezeState.deferredSyncNow = true
                }
                return DebugFreezeState<State>.Settled(
                    state: state,
                    tickId: tickId,
                    membershipEpoch: membershipEpoch
                )
            }
            guard debugIsCurrent(generation) else { throw DebugFreezeError.released }
            guard ContinuousClock.now < deadline else {
                throw DebugFreezeError.settleTimedOut
            }
            try await safeTaskSleep(for: .milliseconds(2))
        }
    }

    /// Release the current freeze generation. Does not wait for an unfinished settle: it sees
    /// the generation is no longer current and publishes nothing, and the keeper refuses to
    /// freeze a released generation again.
    private func debugReleaseFreeze() async {
        let generation = debugFreezeState.generation
        debugFreezeState.count = 0
        debugFreezeState.autoResumeTask?.cancel()
        debugFreezeState.autoResumeTask = nil
        debugFreezeState.autoResumeGeneration &+= 1
        debugFreezeState.settleTask = nil
        debugFreezeState.settled = nil
        let runSyncNow = debugFreezeState.deferredSyncNow
        let runBroadcastOnly = debugFreezeState.deferredBroadcastOnly
        debugFreezeState.deferredSyncNow = false
        debugFreezeState.deferredBroadcastOnly = false

        await keeper.debugResume(generation: generation)

        // Frozen again meanwhile: that freeze defers syncs itself; keep these for its resume.
        guard debugFreezeState.count == 0 else {
            debugFreezeState.deferredSyncNow = debugFreezeState.deferredSyncNow || runSyncNow
            debugFreezeState.deferredBroadcastOnly = debugFreezeState.deferredBroadcastOnly || runBroadcastOnly
            return
        }
        // A full cycle also covers broadcast-only changes.
        if runSyncNow {
            await _syncNowImpl()
        } else if runBroadcastOnly {
            await _syncBroadcastOnlyImpl()
        }
        // That cycle runs without joiners: a tickless land's join that became ready during the
        // freeze (its sync-only turn was skipped) needs its own turn to flip (#69).
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
        guard debugFreezeState.count > 0,
              debugFreezeState.autoResumeGeneration == timerGeneration else { return }
        logger.warning("Debug freeze auto-resumed after timeout", metadata: [
            "landID": .string(landID),
            "freezeCount": .stringConvertible(debugFreezeState.count),
        ])
        await debugReleaseFreeze()
    }
}

/// The executor of a `TransportAdapter` with in-turn sync off: an empty actor whose default
/// serial executor the adapter uses as its own.
private actor AdapterExecutorHost {}
