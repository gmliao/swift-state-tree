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

/// Adapts Transport events to LandKeeper calls.
public actor TransportAdapter<State: StateNodeProtocol>: TransportDelegate {

    private let keeper: LandKeeper<State>
    let transport: any Transport
    /// When set, sync uses enqueueBatch (no await) instead of transport.sendBatch.
    let transportSendQueue: (any TransportSendQueue)?
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
    /// - Skip `clearDirty()` in `LandKeeper.endSync(clearDirtyFlags:)` to avoid recursive reset cost
    ///
    /// Performance: With high update ratio (most fields changing every frame), disabling dirty tracking may be faster.
    /// With low-to-medium update ratio (typical game usage), keep it enabled to save serialization and diff cost.
    private var enableDirtyTracking: Bool
    
    /// When true, use one-pass extraction (state.snapshotForSync) instead of separate broadcast + per-player extractions.
    /// Default is true; set USE_SNAPSHOT_FOR_SYNC=false to use the legacy path.
    private let useSnapshotForSync: Bool
    
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

    /// Membership queue prevents stale join/leave work from delivering after rejoin.
    /// See docs/plans/2026-02-01-membership-queue-reconnect.md.
    private var membershipQueueTail: Task<Void, Never>?

    /// Manager for pending server events (targeted and broadcast).
    /// Encoded once when queued to avoid per-session re-encoding. Cleared after each sync.
    private var pendingEventManager = PendingEventManager()

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
    /// **Core**: `keeper`, `transport`, `transportSendQueue`, `landID`
    /// **Join / lifecycle**: `createGuestSession`, `onLandDestroyed`, `enableLegacyJoin`
    /// **Encoding**: Prefer `encodingConfig` (message + state encoding); otherwise use `codec`, `stateUpdateEncoder`, and optional `pathHashes` / `eventHashes` / `clientEventHashes`
    /// **Tuning**: `enableDirtyTracking`, `expectedSchemaHash`
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
        self.transportSendQueue = transportSendQueue
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

        let envConfig = TransportEnvConfig.fromEnvironment(enableDirtyTrackingDefault: enableDirtyTracking)
        self.enableDirtyTracking = envConfig.enableDirtyTracking
        self.useSnapshotForSync = envConfig.useSnapshotForSync
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

        self.logger.info("Transport encoding configured", metadata: [
            "landID": .string(landID),
            "messageEncoding": .string(self.messageEncoder.encoding.rawValue),
            "stateUpdateEncoding": .string(self.stateUpdateEncoder.encoding.rawValue),
            "dirtyTracking": .string(envConfig.enableDirtyTracking ? "on" : "off"),
            "snapshotForSync": .string(envConfig.useSnapshotForSync ? "on" : "off"),
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
        authInfo: AuthenticatedInfo?
    ) async {
        _ = membershipCoordinator.registerPlayer(
            sessionID: sessionID,
            playerID: playerID,
            authInfo: authInfo
        )
        membershipCoordinator.registerClient(sessionID: sessionID, clientID: clientID)

        // Register with transport for player-based targeting (if supported)
        if let webSocketTransport = transport as? WebSocketTransport {
            await webSocketTransport.registerSession(sessionID, for: playerID)
        }

        logger.info("Session registered via Router: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
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

    public func performJoin(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?
    ) async throws -> JoinResult? {
        try await enqueueMembership {
            try await self.performJoinQueued(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: authInfo
            )
        }
    }

    private func performJoinQueued(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?
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
                authInfo: authInfo
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
                await transport.send(errorData, to: .session(sessionID))
                await Task.yield()
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
                            await transport.send(errorData, to: .session(sessionID))
                            await Task.yield()
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
                    let sessionIDs = membershipCoordinator.sessionIDs(for: playerID)
                    for sessionID in sessionIDs {
                        await transport.send(data, to: .session(sessionID))
                    }
                }
                await Task.yield()
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

            await transport.send(data, to: transportTarget)
            await Task.yield()
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

    /// Encoded targeted event bodies for a given client (sessionID + playerID).
    private func pendingTargetedEventBodies(for sessionID: SessionID, playerID: PlayerID) -> [MessagePackValue] {
        let clientID = membershipCoordinator.clientID(for: sessionID)
        return pendingEventManager.pendingTargetedBodies(
            for: sessionID,
            playerID: playerID,
            clientID: clientID,
            isSessionCurrent: { sessionID, version in
                membershipCoordinator.isSessionCurrent(sessionID, expected: version)
            },
            isPlayerCurrent: { playerID, version in
                membershipCoordinator.isPlayerCurrent(playerID, expected: version)
            }
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

    private func sendEventBodiesSeparately(_ eventBodies: [MessagePackValue], to sessionID: SessionID) async {
        for body in eventBodies {
            guard case .array(let bodyArray) = body else { continue }
            let frame: MessagePackValue = .array([.int(Int64(MessageKindOpcode.event.rawValue))] + bodyArray)
            if let data = try? pack(frame) {
                await transport.send(data, to: .session(sessionID))
            }
        }
        await Task.yield()
    }

    /// Build batch of (Data, EventTarget) for encoded updates. Includes event bodies first when useStateUpdateWithEvents.
    private func buildSendBatch(
        from encodedUpdates: [EncodedSyncUpdate],
        mergeEvents: Bool
    ) -> [(Data, EventTarget)] {
        var batch: [(Data, EventTarget)] = []
        batch.reserveCapacity(encodedUpdates.count * 2)  // room for event bodies + updates
        for encoded in encodedUpdates {
            guard let updateData = encoded.payload else { continue }
            if !mergeEvents, useStateUpdateWithEvents {
                let eventBodies = pendingTargetedEventBodies(for: encoded.sessionID, playerID: encoded.playerID)
                for body in eventBodies {
                    guard case .array(let bodyArray) = body else { continue }
                    let frame: MessagePackValue = .array([.int(Int64(MessageKindOpcode.event.rawValue))] + bodyArray)
                    if let data = try? pack(frame) {
                        batch.append((data, .session(encoded.sessionID)))
                    }
                }
            }
            batch.append((updateData, .session(encoded.sessionID)))
        }
        return batch
    }

    /// Send encoded updates in a single transport call. Reduces WebSocketTransport actor contention.
    /// When transportSendQueue is set, enqueues without await (queue-based path).
    private func sendEncodedUpdatesBatch(
        _ encodedUpdates: [EncodedSyncUpdate],
        mergeEvents: Bool
    ) async {
        let batch = buildSendBatch(from: encodedUpdates, mergeEvents: mergeEvents)
        guard !batch.isEmpty else { return }
        let stateUpdateCount = encodedUpdates.filter { $0.payload != nil }.count
        await sendBatchWithProfiling(batch, stateUpdateCount: stateUpdateCount)
    }

    private func sendEventBody(_ body: MessagePackValue, to target: SwiftStateTree.EventTarget) async {
        guard case .array(let bodyArray) = body else { return }
        let frame: MessagePackValue = .array([.int(Int64(MessageKindOpcode.event.rawValue))] + bodyArray)
        guard let data = try? pack(frame) else { return }

        switch target {
        case .all:
            await transport.send(data, to: .broadcast)
        case .player(let playerID):
            await transport.send(data, to: .player(playerID))
        case .client(let clientID):
            if let sessionID = membershipCoordinator.sessionID(for: clientID) {
                await transport.send(data, to: .session(sessionID))
            } else {
                logger.warning("No session found for client: \(clientID.rawValue)")
            }
        case .session(let sessionID):
            await transport.send(data, to: .session(sessionID))
        case .players(let playerIDs):
            for playerID in playerIDs {
                let sessionIDs = membershipCoordinator.sessionIDs(for: playerID)
                for sessionID in sessionIDs {
                    await transport.send(data, to: .session(sessionID))
                }
            }
        }
        await Task.yield()
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
        profilerCounters?.setSessionCounts(
            connected: membershipCoordinator.connectedSessions.count,
            joined: membershipCoordinator.joinedCount()
        )
        guard !membershipCoordinator.isEmpty else {
            return
        }

        await withSyncState(
            skipLogMessage: "⏭️ Sync skipped: another sync operation is in progress",
            errorLogMessage: "❌ Failed to extract broadcast snapshot"
        ) { state in
            try await runSyncNowCycle(state: state)
        }
    }

    private func withSyncState(
        skipLogMessage: String,
        errorLogMessage: String,
        operation: (State) async throws -> Void
    ) async {
        guard let state = await keeper.beginSync() else {
            if logger.logLevel <= .debug {
                logger.debug("Sync skipped", metadata: ["message": .string(skipLogMessage)])
            }
            return
        }

        do {
            try await operation(state)
        } catch {
            logger.error("Sync operation failed", metadata: [
                "message": .string(errorLogMessage),
                "error": .string("\(error)")
            ])
        }

        await keeper.endSync(clearDirtyFlags: enableDirtyTracking)
    }

    private func runSyncNowCycle(state: State) async throws {
        let shouldCollectChangeMetrics = enableChangeObjectMetrics || enableAutoDirtyTracking
        let (broadcastMode, perPlayerMode) = computeSyncModes(for: state)
        let (broadcastSnapshot, perPlayerByPlayer) = try extractSyncSnapshots(
            from: state,
            broadcastMode: broadcastMode,
            perPlayerMode: perPlayerMode
        )

        let broadcastDiff = syncEngine.computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            onlyPaths: nil,
            mode: broadcastMode
        )

        var metricUpdates = makeMetricUpdatesBuffer(shouldCollect: shouldCollectChangeMetrics)

        if useStateUpdateWithEvents {
            if shouldCollectChangeMetrics,
               let broadcastMetric = try await sendMergedBroadcastUpdateIfNeeded(broadcastDiff: broadcastDiff) {
                metricUpdates.append(broadcastMetric)
            }

            let pendingUpdates = collectPerPlayerOnlyPendingUpdates(
                perPlayerByPlayer: perPlayerByPlayer,
                perPlayerMode: perPlayerMode
            )
            appendMetricUpdates(
                from: pendingUpdates,
                into: &metricUpdates,
                shouldCollect: shouldCollectChangeMetrics
            )
            await encodeAndSendPendingUpdates(pendingUpdates)
            await flushTargetedEventBodiesIfNeeded()
        } else {
            let pendingUpdates = collectCombinedPendingUpdates(
                broadcastDiff: broadcastDiff,
                perPlayerByPlayer: perPlayerByPlayer,
                perPlayerMode: perPlayerMode
            )
            appendMetricUpdates(
                from: pendingUpdates,
                into: &metricUpdates,
                shouldCollect: shouldCollectChangeMetrics
            )
            await encodeAndSendPendingUpdates(pendingUpdates)
        }

        cleanupPendingSyncEvents()
        if shouldCollectChangeMetrics {
            logChangeObjectMetrics(
                updates: metricUpdates,
                broadcastSnapshot: broadcastSnapshot
            )
        }
    }

    private func computeSyncModes(for state: State) -> (broadcastMode: SnapshotMode, perPlayerMode: SnapshotMode) {
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
        broadcastMode: SnapshotMode,
        perPlayerMode: SnapshotMode
    ) throws -> (broadcastSnapshot: StateSnapshot, perPlayerByPlayer: [PlayerID: StateSnapshot]) {
        if useSnapshotForSync {
            let fullMode: SnapshotMode = (enableDirtyTracking && state.isDirty())
                ? .dirtyTracking(state.getDirtyFields())
                : .all
            let playerIDsToSync = membershipCoordinator.joinedPlayerIDs().filter { !initialSyncingPlayers.contains($0) }
            let extracted = try syncEngine.extractWithSnapshotForSync(
                from: state,
                playerIDs: Array(playerIDsToSync),
                mode: fullMode
            )
            return (broadcastSnapshot: extracted.broadcast, perPlayerByPlayer: extracted.perPlayer)
        }

        let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state, mode: broadcastMode)
        var perPlayerByPlayer: [PlayerID: StateSnapshot] = [:]
        perPlayerByPlayer.reserveCapacity(membershipCoordinator.joinedCount())
        for (_, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }
            perPlayerByPlayer[playerID] = try syncEngine.extractPerPlayerSnapshot(
                for: playerID,
                from: state,
                mode: perPlayerMode
            )
        }
        return (broadcastSnapshot: broadcastSnapshot, perPlayerByPlayer: perPlayerByPlayer)
    }

    private func sendMergedBroadcastUpdateIfNeeded(
        broadcastDiff: [StatePatch]
    ) async throws -> StateUpdate? {
        let shouldSendBroadcastUpdate = !broadcastDiff.isEmpty || pendingEventManager.hasAnyEvents
        guard shouldSendBroadcastUpdate else {
            return nil
        }

        guard let firstSession = membershipCoordinator.firstJoined(where: { _, playerID in
            !initialSyncingPlayers.contains(playerID)
        }) else {
            return nil
        }

        let broadcastUpdate: StateUpdate = broadcastDiff.isEmpty ? .noChange : .diff(broadcastDiff)
        let dataToSend: Data
        if let mpEncoder = stateUpdateEncoder as? OpcodeMessagePackStateUpdateEncoder {
            let updateArray = try mpEncoder.encodeToMessagePackArray(
                update: broadcastUpdate,
                landID: landID,
                playerID: firstSession.playerID,
                playerSlot: nil,
                scope: .broadcast
            )
            if let combined = buildStateUpdateWithEventBodies(
                stateUpdateArray: updateArray,
                eventBodies: pendingEventManager.pendingBroadcastBodies(),
                allowEmptyEvents: true
            ) {
                dataToSend = combined
            } else {
                dataToSend = try pack(.array(updateArray))
            }
        } else {
            let updateData = try encodeStateUpdate(
                update: broadcastUpdate,
                playerID: firstSession.playerID,
                playerSlot: nil,
                scope: .broadcast
            )
            if let combined = buildStateUpdateWithEventBodies(
                stateUpdateData: updateData,
                eventBodies: pendingEventManager.pendingBroadcastBodies(),
                allowEmptyEvents: true
            ) {
                dataToSend = combined
            } else {
                dataToSend = updateData
            }
        }

        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }
            profilerCounters?.incrementStateUpdates()
            Task { await transport.send(dataToSend, to: .session(sessionID)) }
        }
        await Task.yield()
        return broadcastUpdate
    }

    private func collectPerPlayerOnlyPendingUpdates(
        perPlayerByPlayer: [PlayerID: StateSnapshot],
        perPlayerMode: SnapshotMode
    ) -> [PendingSyncUpdate] {
        var pendingUpdates: [PendingSyncUpdate] = []
        pendingUpdates.reserveCapacity(membershipCoordinator.joinedCount())

        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }

            guard let perPlayerSnapshot = perPlayerByPlayer[playerID] else {
                continue
            }

            let update = syncEngine.generatePerPlayerUpdateFromSnapshot(
                for: playerID,
                perPlayerSnapshot: perPlayerSnapshot,
                perPlayerMode: perPlayerMode,
                onlyPaths: nil
            )

            if case .noChange = update {
                continue
            }

            pendingUpdates.append(makePendingSyncUpdate(
                sessionID: sessionID,
                playerID: playerID,
                update: update
            ))
        }

        return pendingUpdates
    }

    private func collectCombinedPendingUpdates(
        broadcastDiff: [StatePatch],
        perPlayerByPlayer: [PlayerID: StateSnapshot],
        perPlayerMode: SnapshotMode
    ) -> [PendingSyncUpdate] {
        var pendingUpdates: [PendingSyncUpdate] = []
        pendingUpdates.reserveCapacity(membershipCoordinator.joinedCount())

        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }

            let perPlayerSnapshot = perPlayerByPlayer[playerID] ?? StateSnapshot(values: [:])
            let update = syncEngine.generateUpdateFromBroadcastDiff(
                for: playerID,
                broadcastDiff: broadcastDiff,
                perPlayerSnapshot: perPlayerSnapshot,
                perPlayerMode: perPlayerMode,
                onlyPaths: nil
            )

            if case .noChange = update {
                continue
            }

            pendingUpdates.append(makePendingSyncUpdate(
                sessionID: sessionID,
                playerID: playerID,
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

    private func makeMetricUpdatesBuffer(shouldCollect: Bool) -> [StateUpdate] {
        var updates: [StateUpdate] = []
        if shouldCollect {
            updates.reserveCapacity(membershipCoordinator.joinedCount() + 1)
        }
        return updates
    }

    private func appendMetricUpdates(
        from pendingUpdates: [PendingSyncUpdate],
        into metricUpdates: inout [StateUpdate],
        shouldCollect: Bool
    ) {
        guard shouldCollect else {
            return
        }
        for pending in pendingUpdates {
            metricUpdates.append(pending.update)
        }
    }

    private func encodeAndSendPendingUpdates(_ pendingUpdates: [PendingSyncUpdate]) async {
        guard !pendingUpdates.isEmpty else {
            return
        }

        let encodedUpdates = encodeUpdatesSerially(pendingUpdates)

        let successfulUpdates = encodedUpdates.filter { $0.payload != nil }
        if !successfulUpdates.isEmpty {
            await sendEncodedUpdatesBatch(successfulUpdates, mergeEvents: false)
        }

        for encoded in encodedUpdates where encoded.errorMessage != nil {
            if let errorMessage = encoded.errorMessage {
                logger.error("❌ Failed to encode state update", metadata: [
                    "playerID": .string(encoded.playerID.rawValue),
                    "sessionID": .string(encoded.sessionID.rawValue),
                    "error": .string(errorMessage)
                ])
            }
        }
    }

    private func flushTargetedEventBodiesIfNeeded() async {
        guard pendingEventManager.hasTargetedEvents else {
            return
        }

        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }
            let eventBodies = pendingTargetedEventBodies(for: sessionID, playerID: playerID)
            if !eventBodies.isEmpty {
                await sendEventBodiesSeparately(eventBodies, to: sessionID)
            }
        }
    }

    private func cleanupPendingSyncEvents() {
        pendingEventManager.clearAll()
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
        // Note: Even if no players are connected, we still need to update the broadcast cache
        // This ensures that when a player reconnects, they see the correct state (not stale cache)
        let hasPlayers = !membershipCoordinator.isEmpty

        await withSyncState(
            skipLogMessage: "⏭️ Broadcast-only sync skipped: another sync operation is in progress",
            errorLogMessage: "❌ Failed to sync broadcast-only"
        ) { state in
            // 1. Extract snapshot and compute diff
            let (broadcastDiff, broadcastMode) = try extractAndComputeBroadcastDiff(state: state)
            
            // If no players are connected or no changes, log and return
            guard hasPlayers && !broadcastDiff.isEmpty else {
                logBroadcastCacheUpdate(patchCount: broadcastDiff.count, mode: broadcastMode, hasPlayers: hasPlayers)
                return
            }
            
            // 2. Send broadcast update to all players
            let update = StateUpdate.diff(broadcastDiff)
            let lastUpdateSize = try await sendBroadcastUpdate(update: update)
            
            // 3. Send pending targeted events (if any)
            await sendPendingTargetedEvents()
            
            // 4. Cleanup and log
            cleanupPendingSyncEvents()
            logBroadcastSync(patchCount: broadcastDiff.count, bytes: lastUpdateSize, mode: broadcastMode)
        }
    }
    
    /// Extract broadcast snapshot and compute diff.
    ///
    /// Determines snapshot mode based on dirty tracking, extracts broadcast snapshot,
    /// and computes diff against cached broadcast state.
    ///
    /// - Parameter state: Current state to extract from
    /// - Returns: Tuple of (diff patches, snapshot mode used)
    private func extractAndComputeBroadcastDiff(state: State) throws -> (diff: [StatePatch], mode: SnapshotMode) {
        // Determine snapshot mode based on dirty tracking
        let broadcastMode: SnapshotMode
        if enableDirtyTracking && state.isDirty() {
            let dirtyFields = state.getDirtyFields()
            let syncFields = state.getSyncFields()
            let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
            let broadcastFields = dirtyFields.intersection(broadcastFieldNames)
            
            // Only extract and compare dirty broadcast fields
            broadcastMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
        } else {
            // Dirty tracking disabled or state not dirty: always use .all mode
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
            mode: broadcastMode
        )
        
        return (broadcastDiff, broadcastMode)
    }
    
    /// Send broadcast update to all connected players.
    ///
    /// Encodes and sends state update to all players (excluding initial syncing players).
    /// Uses opcode 107 (with events) or separate frames based on configuration.
    ///
    /// - Parameter update: State update to send
    /// - Returns: Size of last encoded update (for logging)
    private func sendBroadcastUpdate(update: StateUpdate) async throws -> Int? {
        if useStateUpdateWithEvents {
            return try await sendBroadcastUpdateWithEvents(update: update)
        } else {
            return try await sendBroadcastUpdateSeparately(update: update)
        }
    }
    
    /// Send broadcast update with events merged (opcode 107).
    ///
    /// Encodes state update once, merges with pending broadcast events,
    /// and sends to all connected players.
    ///
    /// - Parameter update: State update to send
    /// - Returns: Size of encoded update
    private func sendBroadcastUpdateWithEvents(update: StateUpdate) async throws -> Int? {
        guard let firstSession = membershipCoordinator.firstJoined(where: { _, playerID in
            !initialSyncingPlayers.contains(playerID)
        }) else {
            return nil
        }
        
        // This method is only called when useStateUpdateWithEvents == true,
        // which means stateUpdateEncoder.encoding == .opcodeMessagePack.
        // Only OpcodeMessagePackStateUpdateEncoder returns .opcodeMessagePack,
        // so this cast should always succeed.
        guard let mpEncoder = stateUpdateEncoder as? OpcodeMessagePackStateUpdateEncoder else {
            assertionFailure("useStateUpdateWithEvents is true but encoder is not OpcodeMessagePackStateUpdateEncoder")
            // Fallback: should never happen in practice
            let updateData = try encodeStateUpdate(
                update: update,
                playerID: firstSession.1,
                playerSlot: nil,
                scope: .broadcast
            )
            return updateData.count
        }
        
        let dataToSend: Data
        let updateSize: Int
        
        let updateArray = try mpEncoder.encodeToMessagePackArray(
            update: update,
            landID: landID,
            playerID: firstSession.1,
            playerSlot: nil,
            scope: .broadcast
        )
        if let combined = buildStateUpdateWithEventBodies(
            stateUpdateArray: updateArray,
            eventBodies: pendingEventManager.pendingBroadcastBodies(),
            allowEmptyEvents: true
        ) {
            dataToSend = combined
        } else {
            dataToSend = try pack(.array(updateArray))
        }
        updateSize = dataToSend.count
        
        // Send to all connected players
        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }
            await sendWithProfiling(dataToSend, to: .session(sessionID))
        }
        await Task.yield()
        
        return updateSize
    }
    
    /// Send broadcast update as separate frames (no event merging).
    ///
    /// Encodes state update separately for each player and sends individually.
    /// Handles encoding errors gracefully (logs warning, continues to next player).
    ///
    /// - Parameter update: State update to send
    /// - Returns: Size of last encoded update
    private func sendBroadcastUpdateSeparately(update: StateUpdate) async throws -> Int? {
        var lastUpdateSize: Int?
        
        // Send to all connected players
        // Handle each send separately to avoid one failure stopping all updates
        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }
            
            do {
                let playerSlot = getPlayerSlot(for: playerID)
                let updateData = try stateUpdateEncoder.encode(
                    update: update,
                    landID: landID,
                    playerID: playerID,
                    playerSlot: playerSlot
                )
                lastUpdateSize = updateData.count
                
                // Debug: Log first few bytes to verify encoding format
                if logger.logLevel <= .trace,
                   lastUpdateSize == updateData.count,
                   let preview = String(data: updateData.prefix(100), encoding: .utf8)
                {
                    logger.trace("📤 Encoded update preview", metadata: [
                        "playerID": .string(playerID.rawValue),
                        "bytes": .string("\(updateData.count)"),
                        "preview": .string(preview)
                    ])
                }
                
                await sendWithProfiling(updateData, to: .session(sessionID))
            } catch {
                // Log error but continue sending to other players
                logger.warning("Failed to send broadcast update to session", metadata: [
                    "sessionID": .string(sessionID.rawValue),
                    "error": .string("\(error)")
                ])
            }
        }
        await Task.yield()
        
        return lastUpdateSize
    }
    
    /// Send pending targeted events to all connected players.
    ///
    /// Only called when opcode 107 is enabled and there are targeted events pending.
    /// Sends events separately (not merged with state update).
    private func sendPendingTargetedEvents() async {
        guard useStateUpdateWithEvents, pendingEventManager.hasTargetedEvents else {
            return
        }
        
        for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() {
            if initialSyncingPlayers.contains(playerID) {
                continue
            }
            let eventBodies = pendingTargetedEventBodies(for: sessionID, playerID: playerID)
            if !eventBodies.isEmpty {
                await sendEventBodiesSeparately(eventBodies, to: sessionID)
            }
        }
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
        let payload: Data?
        let errorMessage: String?
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

    /// Encode updates serially
    private func encodeUpdatesSerially(
        _ pendingUpdates: [PendingSyncUpdate]
    ) -> [EncodedSyncUpdate] {
        let encodeStart = ContinuousClock.now
        let result = pendingUpdates.map { pending in
            do {
                let data = try stateUpdateEncoder.encode(
                    update: pending.update,
                    landID: landID,
                    playerID: pending.playerID,
                    playerSlot: pending.playerSlot
                )
                return EncodedSyncUpdate(
                    sessionID: pending.sessionID,
                    playerID: pending.playerID,
                    updateType: pending.updateType,
                    patchCount: pending.patchCount,
                    payload: data,
                    errorMessage: nil
                )
            } catch {
                return EncodedSyncUpdate(
                    sessionID: pending.sessionID,
                    playerID: pending.playerID,
                    updateType: pending.updateType,
                    patchCount: pending.patchCount,
                    payload: nil,
                    errorMessage: "\(error)"
                )
            }
        }
        if let profiler, !pendingUpdates.isEmpty {
            let encodeElapsed = ContinuousClock.now - encodeStart
            let encodeMs = Double(encodeElapsed.components.seconds) * 1000 + Double(encodeElapsed.components.attoseconds) / 1e15
            latencySampleCounter += 1
            if latencySampleCounter % 100 == 0 {
                Task { await profiler.recordEncode(durationMs: encodeMs) }
            }
        }
        return result
    }

    /// Send encoded update to transport.
    ///
    /// - Parameter yieldAfterSend: When true, yields to the executor after sending.
    ///   Set to false when sending in a batch to reduce context switch overhead (yield every N sends instead).
    private func sendEncodedUpdate(
        sessionID: SessionID,
        playerID: PlayerID,
        updateType: String,
        patchCount: Int,
        updateData: Data,
        mergeEvents: Bool,
        yieldAfterSend: Bool = true
    ) async {
        let dataToSend: Data
        if mergeEvents, useStateUpdateWithEvents {
            let eventBodies = pendingEventManager.pendingBroadcastBodies()
            if let combined = buildStateUpdateWithEventBodies(
                stateUpdateData: updateData,
                eventBodies: eventBodies,
                allowEmptyEvents: true
            ) {
                dataToSend = combined
            } else {
                dataToSend = updateData
            }
        } else {
            if useStateUpdateWithEvents {
                let eventBodies = pendingTargetedEventBodies(for: sessionID, playerID: playerID)
                if !eventBodies.isEmpty {
                    await sendEventBodiesSeparately(eventBodies, to: sessionID)
                }
            }
            dataToSend = updateData
        }

        let updateSize = dataToSend.count

        // Verbose per-player state update logging can be noisy at debug level,
        // especially when ticks are running frequently. Use trace instead,
        // and rely on higher‑level logs for normal operation.
        // Only compute logging metadata if trace logging is enabled
        if logger.logLevel <= .trace {
            logger.trace("📤 Sending state update", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "type": .string(updateType),
                "patches": .string("\(patchCount)"),
                "bytes": .string("\(updateSize)")
            ])
        }

        // Log update preview (first 500 chars) - only compute if trace logging is enabled
        if let preview = logger.safePreview(from: dataToSend, maxLength: 500) {
            logger.trace("📤 Update preview", metadata: [
                "playerID": .string(playerID.rawValue),
                "type": .string(updateType),
                "preview": .string(preview)
            ])
        }

        await sendWithProfiling(dataToSend, to: .session(sessionID), yieldAfterSend: yieldAfterSend)
    }

    /// Sync state for a specific player
    ///
    /// This method extracts per-player snapshot and computes diff for a single player.
    /// It reuses the broadcast snapshot to avoid redundant extraction.
    ///
    /// TODO: Optimization opportunities:
    /// - Batch per-player snapshot extraction for multiple players
    /// - Cache per-player snapshots if state hasn't changed
    /// - Consider incremental sync for large state trees
    ///
    /// NOTE: Parallel per-player diff computation was tested but did not show performance improvements.
    /// TaskGroup overhead and actor isolation costs exceeded the benefits, even with 50+ players.
    private func syncState(
        for playerID: PlayerID,
        sessionID: SessionID,
        state: State,
        broadcastDiff: [StatePatch],
        perPlayerMode: SnapshotMode
    ) async {
        do {
            // Extract per-player snapshot (specific to this player)
            let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state, mode: perPlayerMode)

            // Broadcast diff is precomputed once per sync cycle and reused for all players.
            let update = syncEngine.generateUpdateFromBroadcastDiff(
                for: playerID,
                broadcastDiff: broadcastDiff,
                perPlayerSnapshot: perPlayerSnapshot,
                perPlayerMode: perPlayerMode,
                onlyPaths: nil
            )

            // Skip only if noChange - firstSync should always be sent (even if patches are empty)
            // firstSync is a notification that sync has started, not just a data update
            if case .noChange = update {
                return
            }

            let playerSlot = getPlayerSlot(for: playerID)
            let updateData = try stateUpdateEncoder.encode(
                update: update,
                landID: landID,
                playerID: playerID,
                playerSlot: playerSlot
            )

            // Verbose per-player state update logging can be noisy at debug level,
            // especially when ticks are running frequently. Use trace instead,
            // and rely on higher‑level logs for normal operation.
            // Only compute logging metadata if trace logging is enabled
            if logger.logLevel <= .trace {
                let (updateType, patchCount) = update.typeAndPatchCount()
                logger.trace("📤 Sending state update", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "sessionID": .string(sessionID.rawValue),
                    "type": .string(updateType),
                    "patches": .string("\(patchCount)"),
                    "bytes": .string("\(updateData.count)")
                ])
            }

            // Log update preview (first 500 chars) - only compute if trace logging is enabled
            if let preview = logger.safePreview(from: updateData, maxLength: 500) {
                let updateType = update.updateType
                logger.trace("📤 Update preview", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "type": .string(updateType),
                    "preview": .string(preview)
                ])
            }

            await sendWithProfiling(updateData, to: .session(sessionID), yieldAfterSend: true)
        } catch {
            logger.error("❌ Failed to sync state", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
    }

    /// Internal implementation of syncStateForNewPlayer without initialSyncingPlayers management.
    /// Caller is responsible for managing initialSyncingPlayers.
    private func _syncStateForNewPlayer(playerID: PlayerID, sessionID: SessionID) async {
        do {
            let state = await keeper.currentState()

            // Extract a complete snapshot for this player and populate cache.
            let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
            
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
            let updateData = try stateUpdateEncoder.encode(
                update: update,
                landID: landID,
                playerID: playerID,
                playerSlot: playerSlot
            )
            let updateSize = updateData.count

            // Only compute logging metadata if debug logging is enabled
            if logger.logLevel <= .debug {
                logger.debug("📤 Sending initial state (firstSync)", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "sessionID": .string(sessionID.rawValue),
                    "bytes": .string("\(updateSize)"),
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

            // Send encoded update (OpArray format)
            await sendWithProfiling(updateData, to: .session(sessionID), yieldAfterSend: true)

            // Mark as synced so subsequent updates use diffs
            syncEngine.markFirstSyncReceived(for: playerID)
            
        } catch {
            logger.error("❌ Failed to sync initial state", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
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

            await transport.send(responseData, to: .session(sessionID))
            await Task.yield()
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
            await transport.send(errorData, to: .session(sessionID))
            await Task.yield()
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
            await transport.send(errorData, to: .session(sessionID))
            await Task.yield()

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
            await transport.send(responseData, to: .session(sessionID))
            await Task.yield()

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
