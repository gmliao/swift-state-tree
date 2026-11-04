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

/// One frame of a sync phase, addressed to one session of this land.
struct SyncPhaseFrame: Sendable {
    let data: Data
    let sessionID: SessionID
}

/// A session that receives this cycle's frames: joined and not in initial sync (#69).
struct SyncPhaseRecipient: Sendable {
    let sessionID: SessionID
    let playerID: PlayerID
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
///   nothing else, except the encoders' dynamic key tables (see `syncRecoveryPending`). It also reads the adapter's
///   configuration (encoding, dirty-tracking settings) and membership details (player slots,
///   membership stamps) directly; that is synchronous and fine until the sync phase runs inside
///   the keeper's turn.
/// - **commit** (`commitSyncPhase`): writes the staged caches and firstSync marks, removes the
///   consumed events, applies the metric and dirty-tracking updates, and enqueues the frames as
///   one writer element.
///
/// An encode failure does not fail a plan: the update is re-encoded without the patches that do
/// not encode (`droppedUpdates`). A plan that throws (extraction, or anything else that is not
/// an encode failure) commits nothing: caches, firstSync marks, events and metrics are unchanged.
/// The cycle's `beginSync` already cleared the dirty flags, so the next plan is a recovery cycle
/// (`TransportAdapter.syncRecoveryPending`).
struct SyncPhasePlan {
    /// Frames in issue order. Per session: merged broadcast frame, targeted event frames,
    /// per-player state frame.
    var frames: [SyncPhaseFrame] = []
    /// State update frames among `frames` (profiling counter).
    var stateUpdateCount = 0
    var consumedEvents = SyncPhaseConsumedEvents()
    /// Whether the plan diffed every synced field (`syncNow`): only such a commit ends a recovery.
    var coversAllFields = false
    /// Cache updates and firstSync marks; the commit writes them to the sync engine.
    var staged = SyncEngine.StagedCaches()
    /// Patches (or whole updates) dropped because they did not encode.
    var droppedUpdates = 0
    /// The first encode failure's message (for the dropped-updates log).
    var dropReason: String?
    /// Change-object metric input; `nil` when metrics are not collected.
    var metrics: SyncPhaseMetrics?
    var broadcastOnlyLog: SyncPhaseBroadcastLog?
}

/// Adapts Transport events to LandKeeper calls.
public actor TransportAdapter<State: StateNodeProtocol>: TransportDelegate {

    private let keeper: LandKeeper<State>
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
    /// Sessions the server disconnected after a writer ceiling drop.
    var outboundCeilingDisconnects = 0
    /// `landID` for the outbound extension's logs.
    var landIDForOutbound: String { landID }
    /// Logger for the outbound extension.
    var outboundLogger: Logger { logger }
    /// Diagnostics and tests only: awaited by a sync cycle after its frames were enqueued and
    /// before its `endSync` hop, while the cycle still owns the keeper's sync flag. Lets a test
    /// hold a cycle in flight now that the cycle no longer awaits the transport. `nil` (the
    /// default) costs one load per cycle.
    var debugCycleHoldBeforeEndSync: (@Sendable () async -> Void)?

    /// Installs `debugCycleHoldBeforeEndSync` (diagnostics and tests only).
    func setDebugCycleHoldBeforeEndSync(_ hold: (@Sendable () async -> Void)?) {
        debugCycleHoldBeforeEndSync = hold
    }

    /// Installs `syncPlanFaultForTesting` (tests only).
    func setSyncPlanFaultForTesting(_ fault: (@Sendable () throws -> Void)?) {
        syncPlanFaultForTesting = fault
    }

    /// Whether the next sync plan runs as a recovery cycle (tests and diagnostics).
    func isSyncRecoveryPending() -> Bool {
        syncRecoveryPending
    }

    /// The sync engine's caches (tests).
    func syncEngineForTesting() -> SyncEngine {
        syncEngine
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
    private let pathHashes: [String: UInt32]?
    private var syncEngine = SyncEngine()
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
    /// Required consecutive samples before switching dirty tracking mode.
    private let autoDirtyRequiredConsecutiveSamples: Int
    private var autoDirtyOffCandidateCount: Int = 0
    private var autoDirtyOnCandidateCount: Int = 0


    /// Expected schema hash for version verification.
    /// If set, clients must provide matching schemaHash in join metadata.
    private var expectedSchemaHash: String?

    /// Membership coordinator (centralizes all membership management).
    private let membershipCoordinator: MembershipCoordinator
    
    private var initialSyncingPlayers: Set<PlayerID> = []

    /// Set when a sync plan threw (not an encode failure: those drop the patches that do not
    /// encode and commit, see `encodeDroppingUnencodablePatches`): the next plan is a recovery
    /// cycle.
    ///
    /// The failed plan committed nothing, so the caches still hold what every client was last
    /// sent; its `beginSync` already cleared the dirty flags, though. A recovery cycle therefore
    /// extracts `.all` and diffs against the cached baseline (`.empty` under the full-snapshot
    /// strategy), which yields every change, deletions included, at any depth. Every recipient
    /// gets its update typed `.firstSync`, even when empty: the encoders reset the dynamic key
    /// tables of the scope and the client clears its key map for that scope, so key slots the
    /// failed plan's encodes allocated without the client learning them are never referenced. The client applies
    /// a firstSync's patches onto its view like a diff, so the update carries a diff.
    ///
    /// Cleared by the commit of the next plan that covers all fields. A deterministic throw keeps
    /// the land in recovery with nothing sent, as before plan + commit (nothing was sent then
    /// either); `syncRecoveryCycles` and a rate-limited error log make it visible.
    private var syncRecoveryPending = false

    /// Sync cycles that requested `beginSync`, counted in the turn that starts the hop (tests:
    /// once the count is readable, that cycle is suspended in or past its `beginSync` hop).
    private(set) var beginSyncRequests = 0

    /// Failed plans in a row after which no delayed follow-up is scheduled any more.
    static var syncFailedPlanFollowUpLimit: Int { 3 }

    /// Delay of the follow-up after a failed plan on a land without periodic sync.
    static var syncFailedPlanFollowUpDelay: Duration { .milliseconds(100) }

    /// Failed plans in a row (any kind), for the follow-up limit.
    private var consecutiveFailedPlans = 0

    /// When the last dropped-updates error was logged (rate limit).
    private var lastDroppedUpdatesLog: ContinuousClock.Instant?

    /// Patches or updates dropped because they did not encode, since the adapter started
    /// (diagnostics). Each is data loss: the field stays stale on clients until it changes.
    private(set) var syncDroppedUpdates = 0

    /// Tests only: per-player state updates of a player for which this returns `true` fail to
    /// encode (any update type, any encoding).
    private var syncEncodeFaultForTesting: (@Sendable (PlayerID) -> Bool)?

    /// Sync plans run as recovery cycles since the adapter started (diagnostics).
    private(set) var syncRecoveryCycles = 0

    /// When the last "sync in recovery" error was logged (rate limit).
    private var lastSyncRecoveryLog: ContinuousClock.Instant?

    /// Tests only: called at the end of every sync plan, after its diffs were staged and its
    /// frames encoded. A throw fails the plan there.
    private var syncPlanFaultForTesting: (@Sendable () throws -> Void)?

    /// Membership queue prevents stale join/leave work from delivering after rejoin.
    /// See docs/plans/2026-02-01-membership-queue-reconnect.md.
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

    /// Optional transport profiler (when TRANSPORT_PROFILE_JSONL_PATH is set). Low-overhead: counters use atomics; latency uses sampling.
    /// Internal for TransportAdapter+Profiling extension access.
    let profiler: TransportProfilingActor?
    let profilerCounters: TransportProfilerCounters?
    /// Sample 1 in N latency measurements to reduce overhead. Used only when profiler is set.
    var latencySampleCounter: UInt64 = 0

    /// Closure to create PlayerSession for guest users (when JWT validation is enabled but no token is provided).
    /// Only used when JWT validation is enabled, allowGuestMode is true, and no JWT token is provided.
    /// Default implementation uses the sessionID as playerID for deterministic guest identities.
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
    /// **Tuning**: `enableDirtyTracking`, `syncStrategy`, `expectedSchemaHash`; `transportEnvConfig` replaces env lookup entirely (tests/benchmarks)
    /// **Logging**: `logger` (optional). When provided, uses the same logger as the app (e.g. LandManager) for unified logging; when nil, creates a default colored logger. Benchmarks often pass a high log-level logger (e.g. .error) to reduce noise.
    ///
    /// Many options can be overridden at runtime via environment variables (e.g. `ENABLE_DIRTY_TRACKING`, `USE_SNAPSHOT_FOR_SYNC`).
    public init(
        keeper: LandKeeper<State>,
        transport: any Transport,
        transportSendQueue: (any TransportSendQueue)? = nil,
        landID: String,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
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
        self.keeper = keeper
        self.transport = transport
        _ = transportSendQueue
        self.landID = landID
        let adapterScope = "TransportAdapter"
        self.logger = logger.map { $0.withScope(adapterScope) } ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.transport",
            scope: adapterScope
        )

        if let encodingConfig = encodingConfig {
            self.codec = encodingConfig.makeCodec()
            self.messageEncoder = encodingConfig.makeMessageEncoder(
                eventHashes: eventHashes,
                clientEventHashes: clientEventHashes
            )
            self.stateUpdateEncoder = encodingConfig.makeStateUpdateEncoder(
                pathHashes: pathHashes,
                warnIfMissingPathHashes: !suppressMissingPathHashesWarning
            )
            self.pathHashes = pathHashes
            
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
            self.stateUpdateEncoder = stateUpdateEncoder
            self.pathHashes = pathHashes
        }

        self.enableLegacyJoin = enableLegacyJoin

        let envConfig = transportEnvConfig ?? TransportEnvConfig.fromEnvironment(
            enableDirtyTrackingDefault: enableDirtyTracking,
            syncStrategyDefault: syncStrategy
        )
        self.enableDirtyTracking = envConfig.enableDirtyTracking
        self.useSnapshotForSync = envConfig.useSnapshotForSync
        self.syncStrategy = envConfig.syncStrategy
        self.enableChangeObjectMetrics = envConfig.enableChangeObjectMetrics
        self.changeObjectMetricsLogEvery = envConfig.changeObjectMetricsLogEvery
        self.dirtyTrackingMetrics = DirtyTrackingMetrics(emaAlpha: envConfig.changeObjectMetricsEmaAlpha)
        self.dirtyTrackingMetricsState = DirtyTrackingMetrics.State()
        self.enableAutoDirtyTracking = envConfig.enableAutoDirtyTracking
        self.autoDirtyOffThreshold = envConfig.autoDirtyOffThreshold
        self.autoDirtyOnThreshold = envConfig.autoDirtyOnThreshold
        self.autoDirtyRequiredConsecutiveSamples = envConfig.autoDirtyRequiredConsecutiveSamples
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
        // explicitly bypass env parsing entirely, so there is nothing to warn about.
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
            "syncStrategy": .string(envConfig.syncStrategy.rawValue),
            "changeObjectMetrics": .string(envConfig.enableChangeObjectMetrics ? "on" : "off"),
            "autoDirtyTracking": .string(envConfig.enableAutoDirtyTracking ? "on" : "off"),
            "autoDirtyOffThreshold": .string(String(format: "%.3f", envConfig.autoDirtyOffThreshold)),
            "autoDirtyOnThreshold": .string(String(format: "%.3f", envConfig.autoDirtyOnThreshold)),
            "autoDirtyRequiredSamples": .string("\(envConfig.autoDirtyRequiredConsecutiveSamples)")
        ])
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
        let joinedPlayerID = membershipCoordinator.playerID(for: sessionID)

        // If player had joined, handle leave
        if let playerID = joinedPlayerID {
            if logger.logLevel <= .debug {
                logger.debug("Player \(playerID.rawValue) disconnecting: session=\(sessionID.rawValue), clientID=\(clientID.rawValue)")
            }

            membershipCoordinator.invalidateMembership(sessionID: sessionID, playerID: playerID)
            membershipCoordinator.unregisterSession(sessionID: sessionID)

            // Now call keeper.leave() which will trigger syncBroadcastOnly()
            do {
                try await keeper.leave(playerID: playerID, clientID: clientID)
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

            // Clear syncEngine cache for disconnected player
            // This ensures reconnection behaves like first connection
            syncEngine.clearCacheForDisconnectedPlayer(playerID)
            initialSyncingPlayers.remove(playerID)

            // Release playerSlot for this player
            membershipCoordinator.releasePlayerSlot(playerID: playerID)

            logger.info("Client disconnected: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
        } else {
            membershipCoordinator.unregisterSession(sessionID: sessionID)
            logger.info("Client disconnected (was not joined): session=\(sessionID.rawValue)")
        }
    }

    /// Register a session that has been authenticated and joined via LandRouter.
    /// This bypasses the internal join handshake logic of TransportAdapter.
    func _registerSessionImpl(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?,
        acceptedConnectionGeneration: UInt64? = nil
    ) async {
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

    // MARK: - Outbound target expansion

    /// Joined sessions of this land, for `.broadcast` frames.
    func joinedSessionIDs() -> [SessionID] {
        membershipCoordinator.allJoinedEntries().map(\.sessionID)
    }

    /// This land's sessions of `playerID`, for `.player` frames.
    func membershipSessionIDs(for playerID: PlayerID) -> [SessionID] {
        membershipCoordinator.sessionIDs(for: playerID)
    }

    // MARK: - Join Helpers (Shared Logic)

    /// Execute a block while marking player as initial syncing.
    /// Automatically removes the player from initialSyncingPlayers when done (even on error).
    /// This ensures syncNow() and syncBroadcastOnly() skip this player during initial sync.
    private func withInitialSync<T: Sendable>(
        for playerID: PlayerID,
        operation: () async throws -> T
    ) async rethrows -> T {
        initialSyncingPlayers.insert(playerID)
        defer { initialSyncingPlayers.remove(playerID) }
        return try await operation()
    }
    
    /// Mark a player as undergoing initial sync to avoid pre-firstSync updates.
    /// 
    /// Note: Prefer using `withInitialSync(for:operation:)` for automatic cleanup.
    /// This method is kept for backward compatibility but should be avoided in new code.
    func beginInitialSync(for playerID: PlayerID) {
        initialSyncingPlayers.insert(playerID)
    }

    /// Prepare PlayerSession from join request parameters.
    /// Handles priority: join message > JWT payload > guest session.
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

        // Determine playerID: join message > JWT payload > guest session
        let finalPlayerID: String = requestedPlayerID
            ?? jwtAuthInfo?.playerID
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

        // Determine isGuest: true if this is a guest session (no JWT auth and no requested playerID)
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
    }

    /// - Parameter connectionGeneration: The transport connection generation read when the
    ///   session's connection was accepted (see `connectionGenerations`); `nil` reads it now.
    public func performJoin(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?,
        connectionGeneration: UInt64? = nil
    ) async throws -> JoinResult? {
        try await enqueueMembership {
            try await self.performJoinQueued(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: authInfo,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func performJoinQueued(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?,
        connectionGeneration: UInt64?
    ) async throws -> JoinResult? {
        // Attempt to join (updates keeper.players)
        let decision = try await keeper.join(
            session: playerSession,
            clientID: clientID,
            sessionID: sessionID,
            services: LandServices()
        )

        switch decision {
        case .allow(let playerID):
            // Update TransportAdapter state (synchronization point)
            _ = membershipCoordinator.registerPlayer(
                sessionID: sessionID,
                playerID: playerID,
                authInfo: authInfo
            )
            
            // Allocate playerSlot (uses playerID as accountKey by default)
            let slot = allocatePlayerSlot(accountKey: playerID.rawValue, for: playerID)

            // Register session
            await registerSession(
                sessionID: sessionID,
                clientID: clientID,
                playerID: playerID,
                authInfo: authInfo,
                connectionGeneration: connectionGeneration
            )

            // NOTE: Initial state snapshot is NOT sent here anymore.
            // The caller should:
            // 1. First send JoinResponse to client
            // 2. Then call syncStateForNewPlayer() to send the state
            // This ensures client knows join succeeded before receiving state.

            return JoinResult(playerID: playerID, sessionID: sessionID, playerSlot: slot)

        case .deny:
            return nil
        }
    }


    func _onMessageImpl(_ message: Data, from sessionID: SessionID) async {
        let messageSize = message.count
        profilerCounters?.incrementMessagesReceived()
        profilerCounters?.addBytesReceived(Int64(messageSize))

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
        // Try queue mode (opcode 107): synchronous, no await
        if useStateUpdateWithEvents, let body = encodeServerEventBody(event) {
            eventSendingPipeline.queueForMergedSend(
                eventBody: body,
                target: target,
                pendingEventManager: &pendingEventManager,
                membershipCoordinator: membershipCoordinator
            )
            return
        }

        // Fallback to immediate mode: async, await
        await sendEventImmediately(event, to: target)
    }
    
    /// Send event immediately (encode and transport.send).
    ///
    /// This is the fallback path when opcode 107 is disabled or encoding fails.
    /// Handles encoding, validation, logging, and actual transport.send call.
    private func sendEventImmediately(_ event: AnyServerEvent, to target: SwiftStateTree.EventTarget) async {
        do {
            guard let decision = try eventSendingPipeline.prepareImmediateSend(
                event: event,
                target: target,
                membershipCoordinator: membershipCoordinator
            ) else {
                return  // Target is invalid or stale
            }
            
            guard case .immediate(let data, let transportTarget, let targetDescription) = decision else {
                logger.warning("⚠️ Unexpected queued decision in immediate mode")
                return
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
                    enqueueOutbound(data, toSessions: membershipCoordinator.sessionIDs(for: playerID))
                }
                return
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
            enqueueOutbound(data, toSessions: sessionIDs(for: transportTarget))
        } catch {
            logger.error("❌ Failed to send event", metadata: [
                "eventType": .string(event.type),
                "error": .string("\(error)")
            ])
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
            skipLogMessage: "⏭️ Sync skipped: another sync operation is in progress",
            errorLogMessage: "❌ Failed to extract broadcast snapshot"
        ) { state in
            try runFullSyncPhase(state: state)
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
        Task { await self.syncNow() }
    }

    /// After a failed plan (a sync cycle's or a joiner's firstSync) on a land without periodic
    /// sync: one follow-up after a short delay, so the recovery does not wait for an unrelated
    /// sync request. Bounded by `syncFailedPlanFollowUpLimit` failed plans in a row.
    private func noteFailedPlanForFollowUp() {
        consecutiveFailedPlans += 1
        if !keeper.hasPeriodicSync && consecutiveFailedPlans <= Self.syncFailedPlanFollowUpLimit {
            startDelayedFollowUpSync()
        }
    }

    private func startDelayedFollowUpSync() {
        Task {
            try? await safeTaskSleep(for: Self.syncFailedPlanFollowUpDelay)
            await self.syncNow()
        }
    }

    /// Runs `phase` (a sync phase: plan + commit) on a state copy taken by
    /// `LandKeeper.beginSync(clearDirtyFlags:)`.
    ///
    /// Dirty flags are cleared (when `clearDirtyFlags` is set) in the same keeper turn that takes
    /// the copy, so mutations made after it stay dirty for the next cycle (#68). The commit owns
    /// the decision: a committed plan leaves them cleared; a plan that throws makes the next plan a
    /// recovery cycle (`syncRecoveryPending`), which does not depend on them.
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
    private func withSyncState(
        clearDirtyFlags: Bool,
        skipLogMessage: String,
        errorLogMessage: String,
        phase: (State) throws -> Void
    ) async -> Bool {
        beginSyncRequests += 1
        guard let state = await keeper.beginSync(clearDirtyFlags: clearDirtyFlags) else {
            if logger.logLevel <= .debug {
                logger.debug("Sync skipped", metadata: ["message": .string(skipLogMessage)])
            }
            return false
        }

        var completed = false
        do {
            try phase(state)
            completed = true
        } catch {
            logger.error("Sync operation failed", metadata: [
                "message": .string(errorLogMessage),
                "error": .string("\(error)")
            ])
        }

        if let hold = debugCycleHoldBeforeEndSync {
            await hold()
        }
        await keeper.endSync()
        if completed {
            consecutiveFailedPlans = 0
        } else {
            noteFailedPlanForFollowUp()
        }
        return completed && pendingEventManager.hasAnyEvents && !keeper.hasPeriodicSync
    }

    // MARK: - Sync phase: plan + commit

    /// Plans and commits one sync phase in the same actor turn. A plan that throws commits
    /// nothing and makes the next plan a recovery cycle (`syncRecoveryPending`).
    ///
    /// With profiling on, the plan's duration (extraction, diffs and encoding) is sampled as the
    /// encode latency; the clock is read here, never inside a plan.
    private func runSyncPhase(_ plan: () throws -> SyncPhasePlan) throws {
        let planStart: ContinuousClock.Instant? = profiler != nil ? ContinuousClock.now : nil
        let planned: SyncPhasePlan
        do {
            planned = try plan()
        } catch {
            syncRecoveryPending = true
            logSyncRecoveryIfDue(error)
            throw error
        }
        commitSyncPhase(planned)
        if let planStart {
            recordEncodeSample(ContinuousClock.now - planStart)
        }
    }

    /// Logs that the land's sync is in recovery, at most every 10 seconds: a deterministic
    /// failure fails every recovery plan too, and would otherwise log every cycle.
    private func logSyncRecoveryIfDue(_ error: any Error) {
        let now = ContinuousClock.now
        if let last = lastSyncRecoveryLog, now - last < .seconds(10) {
            return
        }
        lastSyncRecoveryLog = now
        logger.error("❌ Sync plan failed; the next cycle is a recovery cycle", metadata: [
            "landID": .string(landID),
            "recoveryCycles": .string("\(syncRecoveryCycles)"),
            "error": .string("\(error)")
        ])
    }

    /// One full sync cycle on `state`: plan, then commit.
    private func runFullSyncPhase(state: State) throws {
        let recovery = syncRecoveryPending
        if recovery {
            syncRecoveryCycles += 1
            profilerCounters?.incrementSyncRecoveryCycles()
        }
        try runSyncPhase {
            try planSyncPhase(
                state: state,
                recipients: syncPhaseRecipients(),
                events: pendingEventManager,
                fullSnapshot: syncStrategy == .fullSnapshot,
                recovery: recovery
            )
        }
    }

    /// Logs dropped updates (data loss), at most every 10 seconds.
    private func logDroppedUpdatesIfDue(_ dropped: Int, reason: String?) {
        let now = ContinuousClock.now
        if let last = lastDroppedUpdatesLog, now - last < .seconds(10) {
            return
        }
        lastDroppedUpdatesLog = now
        logger.error("❌ Sync dropped updates that do not encode (data loss: those fields stay stale on clients until they change)", metadata: [
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
            if initialSyncingPlayers.contains(playerID) {
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
    /// flags were cleared by the keeper when `beginSync` took the copy (#68); a committed plan
    /// that covers all fields ends a recovery.
    private func commitSyncPhase(_ plan: SyncPhasePlan) {
        syncEngine.applyStaged(plan.staged)
        if plan.droppedUpdates > 0 {
            syncDroppedUpdates += plan.droppedUpdates
            profilerCounters?.incrementSyncDroppedUpdates(by: plan.droppedUpdates)
            logDroppedUpdatesIfDue(plan.droppedUpdates, reason: plan.dropReason)
        }
        pendingEventManager.removeConsumed(
            targeted: plan.consumedEvents.targeted,
            broadcast: plan.consumedEvents.broadcast
        )
        if plan.coversAllFields && syncRecoveryPending {
            syncRecoveryPending = false
            logger.info("Sync recovered", metadata: [
                "landID": .string(landID),
                "recoveryCycles": .string("\(syncRecoveryCycles)")
            ])
        }
        if plan.stateUpdateCount > 0 {
            profilerCounters?.incrementStateUpdates(by: plan.stateUpdateCount)
        }
        enqueueFrames(plan.frames.map { sessionFrame($0.data, to: $0.sessionID) })
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
    /// extracts `.all` and diffs against the `.empty` baseline. `recovery` extracts `.all` and
    /// types every recipient's updates `.firstSync`, sent even when empty (see
    /// `syncRecoveryPending`). Updates that fail to encode are re-encoded without the patches
    /// that do not encode (`encodeDroppingUnencodablePatches`).
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
        events: PendingEventManager,
        fullSnapshot: Bool,
        recovery: Bool
    ) throws -> SyncPhasePlan {
        var plan = SyncPhasePlan()
        // A recovery cycle without a recipient reset no client's key tables: stay in recovery.
        plan.coversAllFields = !(recovery && recipients.isEmpty)
        let baseline: SyncEngine.DiffBaseline = fullSnapshot ? .empty : .cached
        let extractAll = fullSnapshot || recovery
        let shouldCollectChangeMetrics = enableChangeObjectMetrics || enableAutoDirtyTracking
        let (requestedBroadcastMode, requestedPerPlayerMode) = computeSyncModes(for: state, extractAll: extractAll)
        // `extractSyncSnapshots` may extract with a different mode than requested
        // when `useSnapshotForSync` is enabled: it derives a single combined dirty-field mode from
        // `state.getDirtyFields()` rather than reusing `requestedBroadcastMode`/`requestedPerPlayerMode`
        // verbatim. Diffing must use the mode that was actually applied during extraction, or fields
        // excluded from extraction (because they weren't in that combined dirty set) get misread as
        // newly-added when compared against the broadcast cache.
        let (broadcastSnapshot, perPlayerByPlayer, broadcastMode, perPlayerMode) = try extractSyncSnapshots(
            from: state,
            recipients: recipients,
            broadcastMode: requestedBroadcastMode,
            perPlayerMode: requestedPerPlayerMode,
            extractAll: extractAll
        )

        let broadcastDiff = syncEngine.computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            onlyPaths: nil,
            mode: broadcastMode,
            baseline: baseline,
            staged: &plan.staged
        )

        // Recipients whose player has no committed firstSync (e.g. its firstSync plan failed):
        // their client view is empty. Read before any update below stages a mark.
        let unsyncedRecipients = recipients.filter {
            !syncEngine.hasReceivedFirstSync($0.playerID, staged: plan.staged)
        }
        let skippedPlayers = Set(unsyncedRecipients.map(\.playerID))

        var metricUpdates: [StateUpdate] = []
        var pendingUpdates: [PendingSyncUpdate]
        if useStateUpdateWithEvents {
            if let broadcastUpdate = try planMergedBroadcastFrame(
                broadcastDiff: broadcastDiff,
                recipients: recipients,
                events: events,
                resetsKeyScope: recovery,
                into: &plan
            ), shouldCollectChangeMetrics {
                metricUpdates.append(broadcastUpdate)
            }
            pendingUpdates = collectPerPlayerOnlyPendingUpdates(
                recipients: recipients,
                perPlayerByPlayer: perPlayerByPlayer,
                perPlayerMode: perPlayerMode,
                baseline: baseline,
                typesFirstSync: recovery,
                skipping: skippedPlayers,
                staged: &plan.staged
            )
        } else {
            pendingUpdates = collectCombinedPendingUpdates(
                recipients: recipients,
                broadcastDiff: broadcastDiff,
                perPlayerByPlayer: perPlayerByPlayer,
                perPlayerMode: perPlayerMode,
                baseline: baseline,
                typesFirstSync: recovery,
                skipping: skippedPlayers,
                staged: &plan.staged
            )
        }
        for recipient in unsyncedRecipients {
            pendingUpdates.append(try planFullViewUpdate(state: state, recipient: recipient, staged: &plan.staged))
        }
        if shouldCollectChangeMetrics {
            metricUpdates.append(contentsOf: pendingUpdates.map(\.update))
            plan.metrics = SyncPhaseMetrics(updates: metricUpdates, broadcastSnapshot: broadcastSnapshot)
        }
        planPerPlayerFrames(
            pendingUpdates,
            recipients: recipients,
            events: events,
            into: &plan
        )

        try syncPlanFaultForTesting?()
        return plan
    }

    /// The whole view of a recipient whose client has none (its firstSync plan failed), as a
    /// diff from empty typed `.firstSync`, like `planFirstSync`. Stages the player's caches from
    /// `.all` snapshots and its firstSync mark.
    private func planFullViewUpdate(
        state: State,
        recipient: SyncPhaseRecipient,
        staged: inout SyncEngine.StagedCaches
    ) throws -> PendingSyncUpdate {
        let snapshot = try syncEngine.lateJoinSnapshot(for: recipient.playerID, from: state, staged: &staged)
        staged.perPlayer[recipient.playerID] = try syncEngine.extractPerPlayerSnapshot(
            for: recipient.playerID,
            from: state,
            mode: .all
        )
        staged.firstSyncReceived.insert(recipient.playerID)
        let patches = syncEngine.computeDiff(from: StateSnapshot(values: [:]), to: snapshot, onlyPaths: nil)
        return makePendingSyncUpdate(
            sessionID: recipient.sessionID,
            playerID: recipient.playerID,
            update: .firstSync(patches)
        )
    }

    /// A recovery cycle's update: always sent, typed `.firstSync` so the encoder and the client
    /// reset the scope's dynamic key table; its patches are the diff against the cache.
    private func recoveryUpdate(_ update: StateUpdate) -> StateUpdate {
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
            for recipient in recipients {
                appendEventFrames(eventBodies, to: recipient.sessionID, into: &plan.frames)
            }
            return nil
        }
        for recipient in recipients {
            plan.frames.append(SyncPhaseFrame(data: data, sessionID: recipient.sessionID))
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
        do {
            return try encodeMergedBroadcastFrame(update: update, playerID: playerID, eventBodies: eventBodies)
        } catch {
            plan.dropReason = plan.dropReason ?? "broadcast frame: \(error)"
            let (data, dropped) = encodeDroppingUnencodablePatches(update.patchesForDroppingEncode) { patches in
                try self.encodeMergedBroadcastFrame(update: .firstSync(patches), playerID: playerID, eventBodies: eventBodies)
            }
            plan.droppedUpdates += dropped
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
                scope: .broadcast
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
    private func planPerPlayerFrames(
        _ pendingUpdates: [PendingSyncUpdate],
        recipients: [SyncPhaseRecipient],
        events: PendingEventManager,
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
                let (data, dropped) = encodeDroppingUnencodablePatches(patches) { kept in
                    try self.encodePerPlayerUpdate(.firstSync(kept), playerID: playerID, playerSlot: playerSlot)
                }
                plan.droppedUpdates += dropped
                for recipient in recipients where recipient.playerID == playerID {
                    payloadBySession[recipient.sessionID] = data
                }
            }
        }

        let targetedEnd = useStateUpdateWithEvents ? events.targetedEventCount : 0
        if useStateUpdateWithEvents {
            plan.consumedEvents.targeted = targetedEnd
        }
        let hasTargetedEvents = useStateUpdateWithEvents && events.hasTargetedEvents
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
                plan.frames.append(SyncPhaseFrame(data: payload, sessionID: recipient.sessionID))
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

        if enableDirtyTracking && state.isDirty() {
            let dirtyFields = state.getDirtyFields()
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

    private func extractSyncSnapshots(
        from state: State,
        recipients: [SyncPhaseRecipient],
        broadcastMode: SnapshotMode,
        perPlayerMode: SnapshotMode,
        extractAll: Bool
    ) throws -> (
        broadcastSnapshot: StateSnapshot,
        perPlayerByPlayer: [PlayerID: StateSnapshot],
        broadcastMode: SnapshotMode,
        perPlayerMode: SnapshotMode
    ) {
        // One entry per player, in recipient order (a player may have several sessions).
        var seenPlayers = Set<PlayerID>()
        let playerIDs = recipients.compactMap { seenPlayers.insert($0.playerID).inserted ? $0.playerID : nil }

        if useSnapshotForSync {
            let fullMode: SnapshotMode = (!extractAll && enableDirtyTracking && state.isDirty())
                ? .dirtyTracking(state.getDirtyFields())
                : .all
            let extracted = try syncEngine.extractWithSnapshotForSync(
                from: state,
                playerIDs: playerIDs,
                mode: fullMode
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

        let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state, mode: broadcastMode)
        var perPlayerByPlayer: [PlayerID: StateSnapshot] = [:]
        perPlayerByPlayer.reserveCapacity(playerIDs.count)
        for playerID in playerIDs {
            perPlayerByPlayer[playerID] = try syncEngine.extractPerPlayerSnapshot(
                for: playerID,
                from: state,
                mode: perPlayerMode
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
                update = recoveryUpdate(update)
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
                update = recoveryUpdate(update)
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
            skipLogMessage: "⏭️ Broadcast-only sync skipped: another sync operation is in progress",
            errorLogMessage: "❌ Failed to sync broadcast-only"
        ) { state in
            // A recovery needs every field and every recipient: run it as a full cycle (it does
            // not read dirty flags, so not clearing them here is still correct).
            if syncRecoveryPending && !membershipCoordinator.isEmpty {
                try runFullSyncPhase(state: state)
                return
            }
            try runSyncPhase {
                try planBroadcastOnlySyncPhase(
                    state: state,
                    recipients: syncPhaseRecipients(),
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
        hasMembers: Bool,
        events: PendingEventManager,
        fullSnapshot: Bool
    ) throws -> SyncPhasePlan {
        var plan = SyncPhasePlan()
        let (broadcastDiff, broadcastMode) = try extractAndComputeBroadcastDiff(
            state: state,
            fullSnapshot: fullSnapshot,
            staged: &plan.staged
        )

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
        staged: inout SyncEngine.StagedCaches
    ) throws -> (diff: [StatePatch], mode: SnapshotMode) {
        // Determine snapshot mode based on dirty tracking
        let broadcastMode: SnapshotMode
        if !fullSnapshot, enableDirtyTracking && state.isDirty() {
            let dirtyFields = state.getDirtyFields()
            let syncFields = state.getSyncFields()
            let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
            let broadcastFields = dirtyFields.intersection(broadcastFieldNames)

            // Only extract and compare dirty broadcast fields
            broadcastMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
        } else {
            // Full-snapshot strategy, dirty tracking disabled, or state not dirty: always use .all mode
            broadcastMode = .all
        }

        // Extract broadcast snapshot (only dirty fields if using dirty tracking)
        let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state, mode: broadcastMode)

        // Compute broadcast diff (only compares dirty fields)
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

        return (broadcastDiff, broadcastMode)
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
            for recipient in recipients {
                appendEventFrames(eventBodies, to: recipient.sessionID, into: &plan.frames)
            }
            return nil
        }
        for recipient in recipients {
            plan.frames.append(SyncPhaseFrame(data: data, sessionID: recipient.sessionID))
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

            plan.frames.append(SyncPhaseFrame(data: updateData, sessionID: recipient.sessionID))
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
        let kept = patches.filter { patch in (try? encode([patch])) != nil }
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
    /// and its next update is a firstSync. The failure still makes the next cycle a recovery cycle
    /// for every recipient, not only this player: firstSync failures are rare, and one rule for
    /// every failed plan is simpler than a per-player variant.
    private func _syncStateForNewPlayer(playerID: PlayerID, sessionID: SessionID) async {
        let state = await keeper.currentState()
        do {
            try runSyncPhase {
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
        var plan = SyncPhasePlan()
        // Extract a complete snapshot for this player; stage the cache population.
        let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state, staged: &plan.staged)

        // Generate full patch set (assume client starts from empty state)
        // This is effectively a "diff from empty" -> series of .set operations
        let patches = syncEngine.computeDiff(
            from: StateSnapshot(values: [:]),
            to: snapshot,
            onlyPaths: nil
        )

        // Wrap in firstSync to trigger Force Definition in Encoder
        let update = StateUpdate.firstSync(patches)

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
            plan.droppedUpdates += dropped
            guard let data else { throw error }
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

        plan.frames = [SyncPhaseFrame(data: updateData, sessionID: sessionID)]
        plan.stateUpdateCount = 1
        // Marked as synced in the commit, so subsequent updates use diffs.
        plan.staged.firstSyncReceived.insert(playerID)

        try syncPlanFaultForTesting?()
        return plan
    }

    /// Sync state for a new player (first connection) using firstSync (OpArray format).
    /// This sends the complete initial state as a series of patches (with compressed keys).
    /// Automatically manages initialSyncingPlayers to prevent concurrent diff updates.
    public func syncStateForNewPlayer(playerID: PlayerID, sessionID: SessionID) async {
        await withInitialSync(for: playerID) {
            await _syncStateForNewPlayer(playerID: playerID, sessionID: sessionID)
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
        do {
            let typeIdentifier = envelope.typeIdentifier
            let handleStart = ContinuousClock.now

            let response = try await keeper.handleActionEnvelope(
                envelope,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID
            )

            profilerCounters?.incrementActions()
            await recordProfiling(startTime: handleStart, operation: .handle)

            await sendActionResponse(
                requestID: requestID,
                actionType: typeIdentifier,
                response: response,
                playerID: playerID,
                sessionID: sessionID
            )
        } catch {
            await handleActionError(
                error: error,
                requestID: requestID,
                envelope: envelope,
                playerID: playerID,
                sessionID: sessionID
            )
        }
    }
    
    /// Send successful action response to client.
    private func sendActionResponse(
        requestID: String,
        actionType: String,
        response: AnyCodable,
        playerID: PlayerID,
        sessionID: SessionID
    ) async {
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

            enqueueOutbound(responseData, to: sessionID)
        } catch {
            logger.error("❌ Failed to send action response", metadata: [
                "requestID": .string(requestID),
                "actionType": .string(actionType),
                "error": .string("\(error)")
            ])
        }
    }
    
    /// Handle action processing error and send error response.
    private func handleActionError(
        error: Error,
        requestID: String,
        envelope: ActionEnvelope,
        playerID: PlayerID,
        sessionID: SessionID
    ) async {
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
            enqueueOutbound(errorData, to: sessionID)
        } catch {
            logger.error("❌ Failed to send error response", metadata: [
                "requestID": .string(requestID),
                "error": .string("\(error)")
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

        await handleDuplicateLoginIfNeeded(for: playerSession)
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

    private func handleDuplicateLoginIfNeeded(for playerSession: PlayerSession) async {
        let targetPlayerID = PlayerID(playerSession.playerID)
        if let oldSessionID = membershipCoordinator.firstSession(for: targetPlayerID) {
            logger.info("Duplicate playerID login detected: \(playerSession.playerID), kicking old session: \(oldSessionID.rawValue)")
            if let oldClientID = membershipCoordinator.clientID(for: oldSessionID) {
                await onDisconnect(sessionID: oldSessionID, clientID: oldClientID)
            }
        }
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
        await withInitialSync(for: joinResult.playerID) {
            await sendJoinResponse(
                requestID: requestID,
                sessionID: sessionID,
                success: true,
                playerID: joinResult.playerID.rawValue,
                playerSlot: joinResult.playerSlot
            )
            await _syncStateForNewPlayer(playerID: joinResult.playerID, sessionID: joinResult.sessionID)
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
                reason: reason
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
        let engine = SyncEngine()
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
            // Read before the copy is taken: a join or leave from here on is not in the copy
            // and must show up as `membershipChanged`.
            let membershipEpoch = membershipCoordinator.membershipEpoch
            // An empty land has nothing to diff: take the copy without clearing dirty flags.
            let hasMembers = !membershipCoordinator.isEmpty
            if let state = await keeper.beginSync(clearDirtyFlags: enableDirtyTracking && hasMembers) {
                do {
                    if hasMembers {
                        try runFullSyncPhase(state: state)
                    }
                } catch {
                    await keeper.endSync()
                    throw error
                }
                if let hold = debugCycleHoldBeforeEndSync {
                    await hold()
                }
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
