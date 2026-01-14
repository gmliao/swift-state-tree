import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack
import Logging

/// Adapts Transport events to LandKeeper calls.
public actor TransportAdapter<State: StateNodeProtocol>: TransportDelegate {

    private let keeper: LandKeeper<State>
    private let transport: any Transport
    private let landID: String
    private let codec: any TransportCodec
    private let messageEncoder: any TransportMessageEncoder
    private let stateUpdateEncoder: any StateUpdateEncoder
    private var syncEngine = SyncEngine()
    private let logger: Logger
    private let enableLegacyJoin: Bool

    // Dirty tracking toggle - default is enabled.
    //
    // When disabled, sync will:
    // - Always use `.all` snapshot mode (no dirty-field filtering)
    // - Skip `clearDirty()` in `LandKeeper.endSync(clearDirtyFlags:)` to避免遞迴重置成本
    //
    // PERFORMANCE NOTE:
    // - 高更新比例（幾乎每幀都在改大部分欄位）時，關閉 dirty tracking 可能更快
    // - 中低更新比例（多數遊戲實際情境）時，建議保持開啟以節省序列化與 diff 成本
    private var enableDirtyTracking: Bool

    /// Whether to enable parallel encoding for JSON codec.
    /// When enabled, multiple player updates are encoded in parallel using TaskGroup.
    /// Only effective when using JSONTransportCodec (thread-safe).
    /// Default is false unless explicitly enabled.
    private var enableParallelEncoding: Bool
    /// Minimum player count required before parallel encoding is considered.
    private var parallelEncodingMinPlayerCount: Int
    /// Target number of players per encoding batch (used to derive worker count).
    private var parallelEncodingBatchSize: Int
    /// Player count threshold to increase per-room concurrency cap.
    private var parallelEncodingHighPlayerThreshold: Int
    /// Per-room concurrency cap for small rooms.
    private var parallelEncodingLowConcurrencyCap: Int
    /// Per-room concurrency cap for larger rooms.
    private var parallelEncodingHighConcurrencyCap: Int
    /// Active room count used to derive a per-room concurrency budget.

    /// Expected schema hash for version verification.
    /// If set, clients must provide matching schemaHash in join metadata.
    private var expectedSchemaHash: String?

    // Track session to player mapping
    private var sessionToPlayer: [SessionID: PlayerID] = [:]
    private var sessionToClient: [SessionID: ClientID] = [:]
    // Track JWT payload information for each session
    private var sessionToAuthInfo: [SessionID: AuthenticatedInfo] = [:]
    private var initialSyncingPlayers: Set<PlayerID> = []
    
    // MARK: - PlayerSlot Tracking
    
    /// Maps playerSlot (Int32) to PlayerID for efficient lookup
    private var slotToPlayer: [Int32: PlayerID] = [:]
    /// Maps PlayerID to playerSlot for reverse lookup
    private var playerToSlot: [PlayerID: Int32] = [:]

    // Computed property: sessions that are connected but not yet joined
    private var connectedSessions: Set<SessionID> {
        Set(sessionToClient.keys).subtracting(Set(sessionToPlayer.keys))
    }

    // Computed property: sessions that have joined
    private var joinedSessions: Set<SessionID> {
        Set(sessionToPlayer.keys)
    }

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

    public init(
        keeper: LandKeeper<State>,
        transport: any Transport,
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
        enableParallelEncoding: Bool? = nil,
        logger: Logger? = nil
    ) {
        self.keeper = keeper
        self.transport = transport
        self.landID = landID
        if let encodingConfig = encodingConfig {
            self.codec = encodingConfig.makeCodec()
            self.messageEncoder = encodingConfig.makeMessageEncoder(
                eventHashes: eventHashes,
                clientEventHashes: clientEventHashes
            )
            self.stateUpdateEncoder = encodingConfig.makeStateUpdateEncoder(pathHashes: pathHashes)
            
            // Validate: Warn if opcodeJsonArray is used without pathHashes
            if encodingConfig.stateUpdate == .opcodeJsonArray && pathHashes == nil {
                logger?.warning(
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
        }
        self.enableLegacyJoin = enableLegacyJoin
        self.enableDirtyTracking = enableDirtyTracking
        self.expectedSchemaHash = expectedSchemaHash
        self.onLandDestroyedCallback = onLandDestroyed

        // Default parallel encoding: disabled unless explicitly enabled.
        if let explicitValue = enableParallelEncoding {
            self.enableParallelEncoding = explicitValue
        } else {
            self.enableParallelEncoding = false
        }
        self.parallelEncodingMinPlayerCount = 20
        self.parallelEncodingBatchSize = 12
        self.parallelEncodingHighPlayerThreshold = 30
        self.parallelEncodingLowConcurrencyCap = 2
        self.parallelEncodingHighConcurrencyCap = 4
        let resolvedLogger: Logger
        if let logger = logger {
            resolvedLogger = logger.withScope("TransportAdapter")
        } else {
            resolvedLogger = createColoredLogger(
                loggerIdentifier: "com.swiftstatetree.transport",
                scope: "TransportAdapter"
            )
        }
        self.logger = resolvedLogger
        if let createGuestSession = createGuestSession {
            self.createGuestSession = createGuestSession
        }
        resolvedLogger.info("Transport encoding configured", metadata: [
            "landID": .string(landID),
            "messageEncoding": .string(self.messageEncoder.encoding.rawValue),
            "stateUpdateEncoding": .string(self.stateUpdateEncoder.encoding.rawValue)
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
        // Check if player already has a slot (reconnection scenario)
        if let existingSlot = playerToSlot[playerID] {
            return existingSlot
        }
        
        // Compute initial slot from hash
        var slot = DeterministicHash.stableInt32(accountKey)
        
        // Linear probing for collision resolution
        while slotToPlayer[slot] != nil {
            slot = (slot &+ 1) & 0x7FFFFFFF  // Keep positive
        }
        
        // Register the slot
        slotToPlayer[slot] = playerID
        playerToSlot[playerID] = slot
        
        return slot
    }
    
    /// Get the playerSlot for an existing player.
    ///
    /// - Parameter playerID: The PlayerID to look up
    /// - Returns: The player's slot, or nil if not found
    public func getPlayerSlot(for playerID: PlayerID) -> Int32? {
        playerToSlot[playerID]
    }
    
    /// Get the PlayerID for a given slot.
    ///
    /// - Parameter slot: The slot to look up
    /// - Returns: The PlayerID, or nil if slot is not occupied
    public func getPlayerID(for slot: Int32) -> PlayerID? {
        slotToPlayer[slot]
    }

    public func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo? = nil) async {
        // Only record connection, don't auto-join
        // Client must send join request explicitly
        sessionToClient[sessionID] = clientID

        // Store JWT payload information if provided (e.g., from JWT validation)
        // This will be used during join request to populate PlayerSession
        if let authInfo = authInfo {
            sessionToAuthInfo[sessionID] = authInfo
            logger.info("Client connected (authenticated, not joined yet): session=\(sessionID.rawValue), clientID=\(clientID.rawValue), playerID=\(authInfo.playerID), metadata=\(authInfo.metadata.count) fields")
        } else {
            logger.info("Client connected (not joined yet): session=\(sessionID.rawValue), clientID=\(clientID.rawValue)")
        }
    }

    public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        // Remove from connected sessions
        sessionToClient.removeValue(forKey: sessionID)
        // Clear JWT payload information
        sessionToAuthInfo.removeValue(forKey: sessionID)

        // If player had joined, handle leave
        if let playerID = sessionToPlayer[sessionID] {
            if logger.logLevel <= .debug {
                logger.debug("Player \(playerID.rawValue) disconnecting: session=\(sessionID.rawValue), clientID=\(clientID.rawValue)")
            }

            // Remove from sessionToPlayer BEFORE calling keeper.leave()
            // This ensures syncBroadcastOnly() only sends to remaining players
            sessionToPlayer.removeValue(forKey: sessionID)

            // Now call keeper.leave() which will trigger syncBroadcastOnly()
            // syncBroadcastOnly() will only see remaining players in sessionToPlayer
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
            if let slot = playerToSlot[playerID] {
                slotToPlayer.removeValue(forKey: slot)
                playerToSlot.removeValue(forKey: playerID)
            }

            logger.info("Client disconnected: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
        } else {
            logger.info("Client disconnected (was not joined): session=\(sessionID.rawValue)")
        }
    }

    /// Register a session that has been authenticated and joined via LandRouter.
    /// This bypasses the internal join handshake logic of TransportAdapter.
    public func registerSession(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?
    ) async {
        sessionToClient[sessionID] = clientID
        sessionToPlayer[sessionID] = playerID
        if let authInfo = authInfo {
            sessionToAuthInfo[sessionID] = authInfo
        }

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
    private func withInitialSync<T>(
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
        let jwtAuthInfo = authInfo ?? sessionToAuthInfo[sessionID]
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
            sessionToPlayer[sessionID] = playerID
            
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


    public func onMessage(_ message: Data, from sessionID: SessionID) async {
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
            // Try to detect if message is in opcode array format
            // If it's an array starting with 101-106, use opcode decoder
            let transportMsg: TransportMessage
            
            // First, try to detect MessagePack binary format (for opcode array)
            if codec.encoding == .messagepack {
                // For MessagePack, try to decode as opcode array first
                // MessagePack opcode arrays start with opcode 101-106
                do {
                    let unpacked = try unpack(message)
                    if case .array(let array) = unpacked, array.count >= 1,
                       case .int(let opcode) = array[0],
                       opcode >= 101 && opcode <= 106 {
                        // This is a MessagePack opcode array - convert to JSON array for OpcodeTransportMessageDecoder
                        let jsonArray = try array.map { value -> Any in
                            switch value {
                            case .int(let v): return v
                            case .uint(let v): return Int(v)
                            case .string(let v): return v
                            case .bool(let v): return v
                            case .array(let arr): return try arr.map { try messagePackValueToJSON($0) }
                            case .map(let map): return try messagePackMapToJSON(map)
                            case .nil: return NSNull()
                            case .binary(let data): return data.base64EncodedString()
                            default: throw TransportMessageDecodingError.invalidFormat("Unsupported MessagePack value type")
                            }
                        }
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonArray)
                        let decoder = OpcodeTransportMessageDecoder()
                        transportMsg = try decoder.decode(from: jsonData)
                    } else {
                        // Not an opcode array, use standard MessagePack codec
                        transportMsg = try codec.decode(TransportMessage.self, from: message)
                    }
                } catch {
                    // If MessagePack decode fails, fall back to standard codec
                    transportMsg = try codec.decode(TransportMessage.self, from: message)
                }
            } else if let json = try? JSONSerialization.jsonObject(with: message),
               let array = json as? [Any],
               array.count >= 1,
               let firstElement = array[0] as? Int,
               firstElement >= 101 && firstElement <= 106 {
                // This is a JSON opcode array format message
                let decoder = OpcodeTransportMessageDecoder()
                transportMsg = try decoder.decode(from: message)
            } else {
                // Standard JSON object format
                transportMsg = try codec.decode(TransportMessage.self, from: message)
            }

            switch transportMsg.kind {
            case .join:
                // If legacy join is enabled, handle it directly (for Single Room Mode)
                if enableLegacyJoin {
                    if case .join(let payload) = transportMsg.payload {
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
                return

            case .joinResponse:
                // Server should not receive joinResponse from client
                logger.warning("Received joinResponse from client (unexpected)", metadata: [
                    "sessionID": .string(sessionID.rawValue)
                ])
                return

            case .error:
                // Server should not receive error from client (errors are server->client)
                logger.warning("Received error message from client (unexpected)", metadata: [
                    "sessionID": .string(sessionID.rawValue)
                ])
                return

            default:
                // For other messages, require player to be joined
                guard let playerID = sessionToPlayer[sessionID],
                      let clientID = sessionToClient[sessionID] else {
                    logger.warning("Message received from session that has not joined: \(sessionID.rawValue)")
                    return
                }

                switch transportMsg.kind {
                case .action:
                    if case .action(let payload) = transportMsg.payload {
                        logger.info("📥 Received action", metadata: [
                            "requestID": .string(payload.requestID),
                            "landID": .string(self.landID),
                            "actionType": .string(payload.action.typeIdentifier),
                            "playerID": .string(playerID.rawValue),
                            "sessionID": .string(sessionID.rawValue)
                        ])

                        // Decode action payload if possible - only compute if trace logging is enabled
                        // Encode AnyCodable to Data for logging preview
                        if let payloadData = try? JSONEncoder().encode(payload.action.payload),
                           let payloadString = logger.safePreview(from: payloadData) {
                            logger.trace("📥 Action payload", metadata: [
                                "requestID": .string(payload.requestID),
                                "payload": .string(payloadString)
                            ])
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
                    if case .actionResponse(let payload) = transportMsg.payload {
                        logger.info("📥 Received action response", metadata: [
                            "requestID": .string(payload.requestID),
                            "playerID": .string(playerID.rawValue),
                            "sessionID": .string(sessionID.rawValue)
                        ])

                        // Log response payload - only compute if trace logging is enabled
                        if let responseData = try? codec.encode(payload.response),
                           let responseString = logger.safePreview(from: responseData) {
                            logger.trace("📥 Response payload", metadata: [
                                "requestID": .string(payload.requestID),
                                "response": .string(responseString)
                            ])
                        }
                    }

                case .event:
                    if case .event(let event) = transportMsg.payload {
                        if case .fromClient(let anyClientEvent) = event {
                            logger.info("📥 Received client event", metadata: [
                                "landID": .string(self.landID),
                                "eventType": .string(anyClientEvent.type),
                                "playerID": .string(playerID.rawValue),
                                "sessionID": .string(sessionID.rawValue)
                            ])

                            // Log event payload - only compute if trace logging is enabled
                            if let payloadData = try? codec.encode(anyClientEvent.payload),
                               let payloadString = logger.safePreview(from: payloadData) {
                                logger.trace("📥 Event payload", metadata: [
                                    "eventType": .string(anyClientEvent.type),
                                    "payload": .string(payloadString)
                                ])
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
                                    try? await transport.send(errorData, to: .session(sessionID))
                                }
                            }
                        } else if case .fromServer = event {
                            logger.warning("Received server event from client (unexpected)", metadata: [
                                "sessionID": .string(sessionID.rawValue)
                            ])
                        }
                    }

                case .join, .joinResponse, .error:
                    // Already handled above
                    break
                }
            }
        } catch {
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
                try await transport.send(errorData, to: .session(sessionID))
            } catch {
                logger.error("❌ Failed to send decode error to client", metadata: [
                    "sessionID": .string(sessionID.rawValue),
                    "error": .string("\(error)")
                ])
            }
        }
    }

    // MARK: - Helper Methods

    /// Send server event to specified target
    public func sendEvent(_ event: AnyServerEvent, to target: SwiftStateTree.EventTarget) async {
        do {
            let transportMsg = TransportMessage.event(
                event: .fromServer(event: event)
            )

            let data = try messageEncoder.encode(transportMsg)
            let dataSize = data.count

            // Convert SwiftStateTree.EventTarget to SwiftStateTreeTransport.EventTarget
            let transportTarget: EventTarget
            let targetDescription: String
            switch target {
            case .all:
                transportTarget = .broadcast
                targetDescription = "broadcast(all)"
            case .player(let playerID):
                transportTarget = .player(playerID)
                targetDescription = "player(\(playerID.rawValue))"
            case .client(let clientID):
                // Find session for this client
                if let sessionID = sessionToClient.first(where: { $0.value == clientID })?.key {
                    transportTarget = .session(sessionID)
                    targetDescription = "client(\(clientID.rawValue)) -> session(\(sessionID.rawValue))"
                } else {
                    logger.warning("No session found for client: \(clientID.rawValue)")
                    return
                }
            case .session(let sessionID):
                transportTarget = .session(sessionID)
                targetDescription = "session(\(sessionID.rawValue))"
            case .players(let playerIDs):
                // For multiple players, send to each individually
                let playerIDsString = playerIDs.map { $0.rawValue }.joined(separator: ", ")
                logger.info("📤 Sending event to multiple players", metadata: [
                    "eventType": .string(event.type),
                    "playerIDs": .string(playerIDsString),
                    "bytes": .string("\(dataSize)")
                ])

                for playerID in playerIDs {
                    let sessionIDs = sessionToPlayer.filter({ $0.value == playerID }).map({ $0.key })
                    for sessionID in sessionIDs {
                        try await transport.send(data, to: .session(sessionID))
                    }
                }
                return
            }

            logger.info("📤 Sending server event", metadata: [
                "eventType": .string(event.type),
                "target": .string(targetDescription),
                "landID": .string(landID),
                "bytes": .string("\(dataSize)"),
                "encoding": .string("\(messageEncoder.encoding.rawValue)")
            ])
            
            // Debug: Log actual data size breakdown for trace level
            if logger.logLevel <= .trace {
                let hexPreview = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.trace("📤 Event data breakdown", metadata: [
                    "eventType": .string(event.type),
                    "totalBytes": .string("\(dataSize)"),
                    "hexPreview": .string(hexPreview),
                    "encoding": .string("\(messageEncoder.encoding.rawValue)")
                ])
            }

            // Log event payload - only compute if trace logging is enabled
            if let payloadData = try? codec.encode(event.payload),
               let payloadString = logger.safePreview(from: payloadData) {
                logger.trace("📤 Event payload", metadata: [
                    "eventType": .string(event.type),
                    "target": .string(targetDescription),
                    "payload": .string(payloadString)
                ])
            }

            try await transport.send(data, to: transportTarget)
        } catch {
            logger.error("❌ Failed to send event", metadata: [
                "eventType": .string(event.type),
                "error": .string("\(error)")
            ])
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
    public func syncNow() async {
        // Early return if no players connected (no one to sync to)
        // This avoids unnecessary snapshot extraction when no players are online
        guard !sessionToPlayer.isEmpty else {
            return
        }

        // Note: When multiple players leave simultaneously, syncBroadcastOnly() is called
        //       for each leave operation. While this is more efficient than syncNow() (only
        //       processes dirty broadcast fields), there's still room for further optimization
        //       by batching or debouncing multiple leave operations into a single sync call.

        // Acquire sync lock to prevent state mutations during sync
        // This ensures we work with a consistent state snapshot
        guard let state = await keeper.beginSync() else {
            // Sync already in progress, skip this sync request
            // TODO: Consider implementing sync queue to handle concurrent sync requests
            // TODO: Add metrics/logging for skipped sync operations
            if logger.logLevel <= .debug {
                logger.debug("⏭️ Sync skipped: another sync operation is in progress")
            }
            return
        }

        do {
            // Determine snapshot modes based on dirty tracking (same logic as SyncEngine.generateDiffFromSnapshots).
            let broadcastMode: SnapshotMode
            let perPlayerMode: SnapshotMode

            if enableDirtyTracking && state.isDirty() {
                let dirtyFields = state.getDirtyFields()
                let syncFields = state.getSyncFields()
                let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
                let perPlayerFieldNames = Set(syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }.map { $0.name })

                let broadcastFields = dirtyFields.intersection(broadcastFieldNames)
                let perPlayerFields = dirtyFields.intersection(perPlayerFieldNames)

                // TODO: Optimization (large player counts):
                // - If `perPlayerFields` is empty, we can skip extracting per-player snapshots and computing per-player diffs
                //   for all players, and send only the shared `broadcastDiff` (while keeping per-player caches intact).
                // - If `broadcastFields` is empty, we could avoid comparing the full broadcast snapshot by tracking
                //   whether any broadcast fields are dirty (already available here) and short-circuit to `broadcastDiff = []`.
                // - For per-player changes, the current model still checks each player. To avoid O(players) work when
                //   a per-player mutation affects only a subset, we need higher-level information (e.g. affected PlayerIDs)
                //   or more granular dirty tracking (e.g. per-player dictionary keys).
                broadcastMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
                perPlayerMode = perPlayerFields.isEmpty ? .all : .dirtyTracking(perPlayerFields)
            } else {
                // Dirty tracking disabled or state not dirty: always use .all mode
                broadcastMode = .all
                perPlayerMode = .all
            }

            // Extract broadcast snapshot once (shared across all players).
            let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state, mode: broadcastMode)

            // Compute broadcast diff ONCE, then reuse for all players.
            // This avoids updating the broadcast cache per player, which would cause only the first player
            // to receive broadcast patches.
            let broadcastDiff = syncEngine.computeBroadcastDiffFromSnapshot(
                currentBroadcast: broadcastSnapshot,
                onlyPaths: nil,
                mode: broadcastMode
            )

            // Collect all pending updates first (diff computation is serial, but encoding can be parallelized)
            var pendingUpdates: [PendingSyncUpdate] = []
            pendingUpdates.reserveCapacity(sessionToPlayer.count)

            for (sessionID, playerID) in sessionToPlayer {
                if initialSyncingPlayers.contains(playerID) {
                    continue
                }

                // Extract per-player snapshot (specific to this player)
                let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(
                    for: playerID,
                    from: state,
                    mode: perPlayerMode
                )

                // Broadcast diff is precomputed once per sync cycle and reused for all players.
                let update = syncEngine.generateUpdateFromBroadcastDiff(
                    for: playerID,
                    broadcastDiff: broadcastDiff,
                    perPlayerSnapshot: perPlayerSnapshot,
                    perPlayerMode: perPlayerMode,
                    onlyPaths: nil
                )

                // Skip only if noChange - firstSync should always be sent (even if patches are empty)
                if case .noChange = update {
                    continue
                }

                let (updateType, patchCount) = describeUpdate(update)
                let playerSlot = getPlayerSlot(for: playerID)
                pendingUpdates.append(PendingSyncUpdate(
                    sessionID: sessionID,
                    playerID: playerID,
                    playerSlot: playerSlot,
                    update: update,
                    updateType: updateType,
                    patchCount: patchCount
                ))
            }

            if !pendingUpdates.isEmpty {
                let encodedUpdates: [EncodedSyncUpdate]
                let decision = parallelEncodingDecision(pendingUpdateCount: pendingUpdates.count)
                let useParallel = decision.useParallel


                if useParallel {
                    // JSON encoding is independent per player, so we can parallelize it safely.
                    encodedUpdates = await encodeUpdatesInParallel(
                        pendingUpdates,
                        maxConcurrency: decision.maxConcurrency
                    )
                } else {
                    encodedUpdates = encodeUpdatesSerially(pendingUpdates)
                }

                for encoded in encodedUpdates {
                    if let payload = encoded.payload {
                        await sendEncodedUpdate(
                            sessionID: encoded.sessionID,
                            playerID: encoded.playerID,
                            updateType: encoded.updateType,
                            patchCount: encoded.patchCount,
                            updateData: payload
                        )
                    } else if let errorMessage = encoded.errorMessage {
                        logger.error("❌ Failed to encode state update", metadata: [
                            "playerID": .string(encoded.playerID.rawValue),
                            "sessionID": .string(encoded.sessionID.rawValue),
                            "error": .string(errorMessage)
                        ])
                    }
                }
            }

            // Release sync lock after successful sync
            // Only clear dirty flags if dirty tracking is enabled
            await keeper.endSync(clearDirtyFlags: enableDirtyTracking)
        } catch {
            logger.error("❌ Failed to extract broadcast snapshot", metadata: [
                "error": .string("\(error)")
            ])
            // TODO: Consider re-syncing after error recovery
            // TODO: Add error metrics to track sync failure rates

            // Always release sync lock, even if error occurred
            // Only clear dirty flags if dirty tracking is enabled
            await keeper.endSync(clearDirtyFlags: enableDirtyTracking)
        }
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
    public func syncBroadcastOnly() async {
        // Note: Even if no players are connected, we still need to update the broadcast cache
        // This ensures that when a player reconnects, they see the correct state (not stale cache)
        let hasPlayers = !sessionToPlayer.isEmpty

        // Acquire sync lock to prevent state mutations during sync
        // This ensures we work with a consistent state snapshot
        guard let state = await keeper.beginSync() else {
            // Sync already in progress, skip this sync request
            // TODO: For broadcast-only sync, consider allowing concurrent execution
            // since it's read-only (but cache updates need coordination)
            if logger.logLevel <= .debug {
                logger.debug("⏭️ Broadcast-only sync skipped: another sync operation is in progress")
            }
            return
        }

        do {

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

            // If no players are connected, we still update the cache but don't send messages
            guard hasPlayers && !broadcastDiff.isEmpty else {
                if !hasPlayers && logger.logLevel <= .debug {
                    logger.debug("📤 Broadcast cache updated (no players connected)", metadata: [
                        "patches": .string("\(broadcastDiff.count)"),
                        "mode": .string("\(broadcastMode)")
                    ])
                }
                await keeper.endSync(clearDirtyFlags: enableDirtyTracking)
                return
            }

            let update = StateUpdate.diff(broadcastDiff)
            var lastUpdateSize: Int?

            // Send to all connected players
            // Handle each send separately to avoid one failure stopping all updates
            for (sessionID, playerID) in sessionToPlayer {
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
                    
                    try await transport.send(updateData, to: .session(sessionID))
                } catch {
                    // Log error but continue sending to other players
                    logger.warning("Failed to send broadcast update to session", metadata: [
                        "sessionID": .string(sessionID.rawValue),
                        "error": .string("\(error)")
                    ])
                }
            }

            // Only compute logging metadata if debug logging is enabled
            if logger.logLevel <= .debug {
                logger.debug("📤 Broadcast-only sync", metadata: [
                    "players": .string("\(sessionToPlayer.count)"),
                    "patches": .string("\(broadcastDiff.count)"),
                    "bytes": .string("\(lastUpdateSize ?? 0)"),
                    "mode": .string("\(broadcastMode)")
                ])
            }

            // Release sync lock after successful sync
            // Only clear dirty flags if dirty tracking is enabled
            await keeper.endSync(clearDirtyFlags: enableDirtyTracking)
        } catch {
            logger.error("❌ Failed to sync broadcast-only", metadata: [
                "error": .string("\(error)")
            ])

            // Always release sync lock, even if error occurred
            // Only clear dirty flags if dirty tracking is enabled
            await keeper.endSync(clearDirtyFlags: enableDirtyTracking)
        }
    }

    // MARK: - Parallel Encoding Support

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

    /// Determine if parallel encoding should be used and compute effective concurrency.
    /// Decide whether to use parallel encoding and calculate the effective concurrency.
    ///
    /// In adaptive mode, the concurrency is calculated as:
    /// `min(perRoomCap, batchWorkers, roomBudget, pendingUpdateCount)`
    ///
    /// - **perRoomCap**: Per-room concurrency cap based on player count
    ///   - Players < highThreshold (30): lowCap (2)
    ///   - Players >= highThreshold: highCap (4)
    /// - **batchWorkers**: Number of workers needed based on batch size
    ///   - Calculated as: `ceil(pendingUpdateCount / batchSize)`
    ///   - batchSize defaults to 12
    /// - **pendingUpdateCount**: Actual number of updates to encode (hard limit)
    ///
    /// Note: `maxConcurrency` is not included in the min() calculation because
    /// `perRoomCap` and `batchWorkers` are typically much smaller, so `maxConcurrency`
    /// rarely becomes the limiting factor. Each adapter only knows its own room,
    /// so it can use the full global budget.
    ///
    /// - Parameter pendingUpdateCount: Number of player updates to encode
    /// - Returns: Tuple of (should use parallel encoding, effective concurrency level)
    private func parallelEncodingDecision(
        pendingUpdateCount: Int
    ) -> (useParallel: Bool, maxConcurrency: Int) {
        guard stateUpdateEncoder is JSONStateUpdateEncoder
            || stateUpdateEncoder is OpcodeJSONStateUpdateEncoder
        else {
            return (false, 1)
        }
        guard enableParallelEncoding else {
            return (false, 1)
        }
        guard pendingUpdateCount > 1 else {
            return (false, 1)
        }

        // Calculate concurrency based on multiple factors (adaptive mode)
        let minPlayers = max(1, parallelEncodingMinPlayerCount)
        if pendingUpdateCount < minPlayers {
            return (false, 1)
        }

        // Calculate per-room cap based on player count
        let highThreshold = max(minPlayers, parallelEncodingHighPlayerThreshold)
        let lowCap = max(1, parallelEncodingLowConcurrencyCap)
        let highCap = max(lowCap, parallelEncodingHighConcurrencyCap)
        let perRoomCap = pendingUpdateCount >= highThreshold ? highCap : lowCap
        
        // Calculate batch workers based on batch size
        let batchSize = max(1, parallelEncodingBatchSize)
        let batchWorkers = max(1, (pendingUpdateCount + batchSize - 1) / batchSize)
        
        // Final concurrency is the minimum of all constraints
        // Note: maxConcurrency is not included here because perRoomCap and batchWorkers
        // are typically much smaller, so maxConcurrency rarely becomes the limiting factor
        let concurrency = min(perRoomCap, batchWorkers, pendingUpdateCount)

        return (concurrency > 1, concurrency)
    }

    /// Enable or disable parallel encoding at runtime.
    ///
    /// - Parameter enabled: `true` to enable parallel encoding (only effective for JSON encoders),
    ///   `false` to disable and use serial encoding.
    public func setParallelEncodingEnabled(_ enabled: Bool) {
        enableParallelEncoding = enabled
    }

    /// Check whether parallel encoding is currently enabled.
    public func isParallelEncodingEnabled() -> Bool {
        enableParallelEncoding
    }


    /// Set the minimum player count required to consider parallel encoding.
    public func setParallelEncodingMinPlayerCount(_ count: Int) {
        parallelEncodingMinPlayerCount = max(1, count)
    }

    /// Set the target batch size (players per encoding task).
    public func setParallelEncodingBatchSize(_ batchSize: Int) {
        parallelEncodingBatchSize = max(1, batchSize)
    }

    /// Set the per-room concurrency caps and high-player threshold.
    public func setParallelEncodingConcurrencyCaps(
        lowPlayerCap: Int,
        highPlayerCap: Int,
        highPlayerThreshold: Int
    ) {
        parallelEncodingLowConcurrencyCap = max(1, lowPlayerCap)
        parallelEncodingHighConcurrencyCap = max(parallelEncodingLowConcurrencyCap, highPlayerCap)
        parallelEncodingHighPlayerThreshold = max(1, highPlayerThreshold)
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

    /// Encode updates serially (fallback when parallel encoding is disabled)
    private func encodeUpdatesSerially(
        _ pendingUpdates: [PendingSyncUpdate]
    ) -> [EncodedSyncUpdate] {
        pendingUpdates.map { pending in
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
    }

    /// Encode updates in parallel using TaskGroup
    /// This is safe for JSON encoders as JSONEncoder is thread-safe
    private func encodeUpdatesInParallel(
        _ pendingUpdates: [PendingSyncUpdate],
        maxConcurrency: Int
    ) async -> [EncodedSyncUpdate] {
        guard !pendingUpdates.isEmpty else {
            return []
        }
        // Capture encoder once before parallel execution
        let stateUpdateEncoder = self.stateUpdateEncoder
        let landID = self.landID
        let maxConcurrency = max(1, maxConcurrency)
        let workerCount = min(maxConcurrency, pendingUpdates.count)
        let chunkSize = (pendingUpdates.count + workerCount - 1) / workerCount

        return await withTaskGroup(of: [EncodedSyncUpdate].self, returning: [EncodedSyncUpdate].self) { group in
            let encodeUpdate: @Sendable (PendingSyncUpdate) -> EncodedSyncUpdate = { pending in
                do {
                    // Reuse the same encoder instance (JSONEncoder is thread-safe)
                    let data = try stateUpdateEncoder.encode(
                        update: pending.update,
                        landID: landID,
                        playerID: pending.playerID
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

            for startIndex in stride(from: 0, to: pendingUpdates.count, by: chunkSize) {
                let endIndex = min(startIndex + chunkSize, pendingUpdates.count)
                group.addTask {
                    pendingUpdates[startIndex..<endIndex].map(encodeUpdate)
                }
            }

            var results: [EncodedSyncUpdate] = []
            results.reserveCapacity(pendingUpdates.count)
            for await chunkResult in group {
                results.append(contentsOf: chunkResult)
            }
            return results
        }
    }

    /// Send encoded update to transport
    private func sendEncodedUpdate(
        sessionID: SessionID,
        playerID: PlayerID,
        updateType: String,
        patchCount: Int,
        updateData: Data
    ) async {
        let updateSize = updateData.count

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
        if let preview = logger.safePreview(from: updateData, maxLength: 500) {
            logger.trace("📤 Update preview", metadata: [
                "playerID": .string(playerID.rawValue),
                "type": .string(updateType),
                "preview": .string(preview)
            ])
        }

        do {
            try await transport.send(updateData, to: .session(sessionID))
        } catch {
            logger.error("❌ Failed to sync state", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
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
            let updateSize = updateData.count

            let updateType: String
            let patchCount: Int
            switch update {
            case .noChange:
                updateType = "noChange"
                patchCount = 0
            case .firstSync(let patches):
                updateType = "firstSync"
                patchCount = patches.count
            case .diff(let patches):
                updateType = "diff"
                patchCount = patches.count
            }

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
            if let preview = logger.safePreview(from: updateData, maxLength: 500) {
                logger.trace("📤 Update preview", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "type": .string(updateType),
                    "preview": .string(preview)
                ])
            }

            try await transport.send(updateData, to: .session(sessionID))
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
            // Thread-safe DynamicKeyTable ensures no corruption during parallel encoding
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
            try await transport.send(updateData, to: .session(sessionID))
            
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

            let response = try await keeper.handleActionEnvelope(
                envelope,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID
            )

            // Send action response
            let actionResponse = TransportMessage.actionResponse(
                requestID: requestID,
                response: response
            )
            let responseData = try messageEncoder.encode(actionResponse)
            let responseSize = responseData.count

            // Only compute logging metadata if info logging is enabled
            if logger.logLevel <= .info {
            logger.info("📤 Sending action response", metadata: [
                "requestID": .string(requestID),
                "actionType": .string(typeIdentifier),
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "bytes": .string("\(responseSize)")
            ])
            }

            // Log response payload - only compute if trace logging is enabled
            if let preview = logger.safePreview(from: responseData, maxLength: 500) {
                logger.trace("📤 Action response payload", metadata: [
                    "requestID": .string(requestID),
                    "actionType": .string(typeIdentifier),
                    "response": .string(preview)
                ])
            }

            try await transport.send(responseData, to: .session(sessionID))

        } catch {
            logger.error("❌ Failed to handle action", metadata: [
                "requestID": .string(requestID),
                "actionType": .string(envelope.typeIdentifier),
                "playerID": .string(playerID.rawValue),
                "error": .string("\(error)")
            ])

            // Send error response using unified error format
            do {
                let errorCode: ErrorCode
                let errorMessage: String

                if let landError = error as? LandError {
                    switch landError {
                    case .actionNotRegistered:
                        errorCode = .actionNotRegistered
                        errorMessage = "Action not registered: \(envelope.typeIdentifier)"
                    default:
                        errorCode = .actionHandlerError
                        errorMessage = "\(error)"
                    }
                } else {
                    errorCode = .actionHandlerError
                    errorMessage = "\(error)"
                }

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
                try await transport.send(errorData, to: .session(sessionID))
            } catch {
                logger.error("❌ Failed to send error response", metadata: [
                    "requestID": .string(requestID),
                    "error": .string("\(error)")
                ])
            }
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
        // Phase 1: Validation (no state modification)
        guard let clientID = sessionToClient[sessionID] else {
            logger.warning("Join request from unknown session: \(sessionID.rawValue)")
            await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinSessionNotConnected, message: "Session not connected")
            return
        }

        // Check if already joined
        if sessionToPlayer[sessionID] != nil {
            logger.warning("Join request from already joined session: \(sessionID.rawValue)")
            await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinAlreadyJoined, message: "Already joined")
            return
        }

        // Verify landID matches
        guard landID == self.landID else {
            logger.warning("Join request with mismatched landID: expected=\(self.landID), received=\(landID)")
            await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinLandIDMismatch, message: "Land ID mismatch", details: [
                "expected": AnyCodable(self.landID),
                "received": AnyCodable(landID)
            ])
            return
        }

        // Verify schemaHash matches (if configured)
        if let expected = expectedSchemaHash {
            let clientSchemaHash = metadata?["schemaHash"]?.base as? String
            if clientSchemaHash != expected {
                logger.warning("Join request with mismatched schemaHash: expected=\(expected), received=\(clientSchemaHash ?? "nil")")
                await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinSchemaHashMismatch, message: "Schema version mismatch", details: [
                    "expected": AnyCodable(expected),
                    "received": AnyCodable(clientSchemaHash ?? "nil")
                ])
                return
            }
        }

        // Phase 2: Preparation (no state modification)
        // Use shared helper to prepare PlayerSession
        let jwtAuthInfo = sessionToAuthInfo[sessionID]
        let playerSession = preparePlayerSession(
            sessionID: sessionID,
            clientID: clientID,
            requestedPlayerID: requestedPlayerID,
            deviceID: deviceID,
            metadata: metadata,
            authInfo: jwtAuthInfo
        )

        // Log metadata sources for debugging
        if let jwtAuthInfo = jwtAuthInfo, logger.logLevel <= .debug {
            logger.debug("Using JWT payload for join", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "jwtPlayerID": .string(jwtAuthInfo.playerID),
                "jwtMetadataCount": .string("\(jwtAuthInfo.metadata.count)"),
                "finalPlayerID": .string(playerSession.playerID),
                "finalMetadataCount": .string("\(playerSession.metadata.count)")
            ])
        }

        // Phase 3: Check for duplicate playerID and kick old session (Kick Old strategy)
        let targetPlayerID = PlayerID(playerSession.playerID)
        let existingSessions = getSessions(for: targetPlayerID)
        if let oldSessionID = existingSessions.first {
            logger.info("Duplicate playerID login detected: \(playerSession.playerID), kicking old session: \(oldSessionID.rawValue)")
            // Get old clientID before disconnecting
            if let oldClientID = sessionToClient[oldSessionID] {
                // Disconnect old session (this will call keeper.leave() and clean up state)
                await onDisconnect(sessionID: oldSessionID, clientID: oldClientID)
            }
        }

        // Phase 4: Atomic join operation (with rollback on failure)
        var joinSucceeded = false
        var playerID: PlayerID?

        defer {
            // Rollback sessionToPlayer if join failed
            if !joinSucceeded, let pid = playerID {
                sessionToPlayer.removeValue(forKey: sessionID)
                logger.warning("Rolled back join state for session \(sessionID.rawValue), player \(pid.rawValue)")
            }
        }

        do {
            // Use shared helper to perform join
            if let joinResult = try await performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: jwtAuthInfo
            ) {
                playerID = joinResult.playerID
                joinSucceeded = true
                
                // Use withInitialSync to protect the entire initial sync process
                // This ensures syncNow() called during joinResponse won't send diff to this player
                await withInitialSync(for: joinResult.playerID) {
                    // IMPORTANT: Send JoinResponse FIRST, then StateSnapshot
                    // This ensures client knows join succeeded before receiving state

                    // 1. Send join response with playerSlot
                    await sendJoinResponse(requestID: requestID, sessionID: sessionID, success: true, playerID: joinResult.playerID.rawValue, playerSlot: joinResult.playerSlot)

                    // 2. Send initial state snapshot AFTER JoinResponse
                    // Use internal version to avoid double withInitialSync wrapping
                    await _syncStateForNewPlayer(playerID: joinResult.playerID, sessionID: joinResult.sessionID)
                }

                logger.info("Client joined: session=\(sessionID.rawValue), player=\(joinResult.playerID.rawValue), playerID=\(playerSession.playerID)")
            } else {
                // Join denied
                logger.warning("Join denied for session \(sessionID.rawValue)")
                await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinDenied, message: "Join denied")
            }
        } catch {
            // Join failed (e.g., JoinError.roomIsFull)
            logger.error("Join failed for session \(sessionID.rawValue): \(error)")
            let errorCode: ErrorCode
            let errorMessage: String
            if error.localizedDescription.contains("full") || error.localizedDescription.contains("Full") {
                errorCode = .joinRoomFull
                errorMessage = "Room is full"
            } else {
                errorCode = .joinDenied
                errorMessage = "\(error)"
            }
            await sendJoinError(requestID: requestID, sessionID: sessionID, code: errorCode, message: errorMessage)
        }
    }

    // MARK: - State Query Methods

    /// Check if a session is connected (but may not have joined)
    public func isConnected(sessionID: SessionID) -> Bool {
        sessionToClient[sessionID] != nil
    }

    /// Check if a session has joined
    public func isJoined(sessionID: SessionID) -> Bool {
        sessionToPlayer[sessionID] != nil
    }

    /// Get the playerID for a session (if joined)
    public func getPlayerID(for sessionID: SessionID) -> PlayerID? {
        sessionToPlayer[sessionID]
    }

    /// Get all sessions for a playerID
    public func getSessions(for playerID: PlayerID) -> [SessionID] {
        sessionToPlayer.filter { $0.value == playerID }.map { $0.key }
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
            try await transport.send(errorData, to: .session(sessionID))

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
            try await transport.send(responseData, to: .session(sessionID))

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
