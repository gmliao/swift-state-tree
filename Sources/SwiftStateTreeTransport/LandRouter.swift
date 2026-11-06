import Foundation
import SwiftStateTree
import Logging

/// Router for managing WebSocket connections and routing join requests to appropriate Lands.
///
/// LandRouter is responsible for:
/// - WS connection management (onConnect / onDisconnect)
/// - Join routing (landType → Land)
/// - Session binding (sessionToBoundLandID)
/// - Message routing (forwarding messages to bound TransportAdapter)
///
/// ## Architecture
///
/// ```
/// WebSocket Endpoint
///        │
///        ▼
/// ┌─────────────────┐
/// │   LandRouter    │  ← WS connection management, Join routing
/// └────────┬────────┘
///          │
///    ┌─────┼─────┐
///    ▼     ▼     ▼
/// ┌─────┐┌─────┐┌─────┐
/// │ TA  ││ TA  ││ TA  │  ← TransportAdapter (protocol conversion)
/// └──┬──┘└──┬──┘└──┬──┘
///    ▼     ▼     ▼
/// ┌─────┐┌─────┐┌─────┐
/// │ LK  ││ LK  ││ LK  │  ← LandKeeper (state management)
/// └─────┘└─────┘└─────┘
/// ```
public actor LandRouter<State: StateNodeProtocol>: TransportDelegate {
    
    // MARK: - Dependencies
    
    private let landManager: LandManager<State>
    private let landTypeRegistry: LandTypeRegistry<State>
    private let transport: WebSocketTransport
    private let logger: Logger
    private let encodingConfig: TransportEncodingConfig
    private let codec: any TransportCodec
    private let messageEncoder: any TransportMessageEncoder
    
    // MARK: - Session Management
    
    /// Maps sessionID to clientID for connected sessions
    private var sessionToClient: [SessionID: ClientID] = [:]
    /// Connection generation read when the session's connection was accepted (passed to the
    /// land's adapter on join, so its frames are stamped for that connection).
    private var sessionToConnectionGeneration: [SessionID: UInt64] = [:]
    
    /// Maps sessionID to bound landID after successful join
    private var sessionToBoundLandID: [SessionID: LandID] = [:]
    
    /// Maps sessionID to auth info (from JWT or other auth mechanisms)
    private var sessionToAuthInfo: [SessionID: AuthenticatedInfo] = [:]
    
    /// Guest session factory (optional)
    private let createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)?
    
    // MARK: - Handshake State Machine
    
    /// Handshake phase for managing join protocol
    private enum HandshakePhase {
        case awaitingJoin    // Waiting for join (only accepts JSON join)
        case joined          // Handshake completed (uses configured encoding)
    }
    
    /// Tracks handshake phase for each session
    private var sessionHandshakePhase: [SessionID: HandshakePhase] = [:]
    
    // MARK: - Configuration
    
    /// Allow auto-creating land when join with instanceId but land doesn't exist.
    ///
    /// **Security Note**: When `true`, clients can create rooms by specifying any instanceId.
    /// This is useful for demo/testing but should be `false` in production.
    /// Default: `false` (secure: prevent unauthorized room creation)
    private let allowAutoCreateOnJoin: Bool
    
    // MARK: - Initialization
    
    /// Initialize a LandRouter.
    ///
    /// - Parameters:
    ///   - landManager: Manager for Land instances
    ///   - landTypeRegistry: Registry for landType → LandDefinition mapping
    ///   - transport: WebSocket transport for sending messages
    ///   - createGuestSession: Optional factory for creating guest sessions
    ///   - allowAutoCreateOnJoin: Allow auto-creating land when join with instanceId but land doesn't exist (default: false)
    ///   - logger: Optional logger instance
    public init(
        landManager: LandManager<State>,
        landTypeRegistry: LandTypeRegistry<State>,
        transport: WebSocketTransport,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        allowAutoCreateOnJoin: Bool = false,
        transportEncoding: TransportEncodingConfig = .jsonOpcode,
        logger: Logger? = nil
    ) {
        self.landManager = landManager
        self.landTypeRegistry = landTypeRegistry
        self.transport = transport
        self.createGuestSession = createGuestSession
        self.allowAutoCreateOnJoin = allowAutoCreateOnJoin
        self.encodingConfig = transportEncoding
        self.codec = transportEncoding.makeCodec()
        self.messageEncoder = transportEncoding.makeMessageEncoder()
        let resolvedLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.transport",
            scope: "LandRouter"
        )
        self.logger = resolvedLogger

        resolvedLogger.info("LandRouter encoding configured", metadata: [
            "messageEncoding": .string(self.messageEncoder.encoding.rawValue),
            "codecEncoding": .string(self.codec.encoding.rawValue)
        ])
    }
    
    // MARK: - Connection Management
    
    /// Called when a client connects via WebSocket.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier
    ///   - clientID: The client identifier
    ///   - authInfo: Optional authenticated information (e.g., from JWT validation)
    public func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo? = nil) async {
        sessionToClient[sessionID] = clientID
        sessionHandshakePhase[sessionID] = .awaitingJoin  // Initialize handshake state
        sessionToConnectionGeneration[sessionID] = await transport.connectionGeneration(for: sessionID)
        
        if let authInfo = authInfo {
            sessionToAuthInfo[sessionID] = authInfo
            logger.info("Client connected (authenticated): session=\(sessionID.rawValue), clientID=\(clientID.rawValue), playerID=\(authInfo.playerID)")
        } else {
            logger.info("Client connected: session=\(sessionID.rawValue), clientID=\(clientID.rawValue)")
        }
    }
    
    /// Called when a client disconnects.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier
    ///   - clientID: The client identifier
    public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        // Get bound landID before cleanup
        let boundLandID = sessionToBoundLandID[sessionID]
        
        // Clean up session state
        sessionToClient.removeValue(forKey: sessionID)
        sessionToConnectionGeneration.removeValue(forKey: sessionID)
        sessionToAuthInfo.removeValue(forKey: sessionID)
        sessionToBoundLandID.removeValue(forKey: sessionID)
        sessionHandshakePhase.removeValue(forKey: sessionID)  // Clean up handshake state
        
        // If session was bound to a land, notify the TransportAdapter
        if let landID = boundLandID {
            if let container = await landManager.getLand(landID: landID) {
                let log = logger
                Task {
                    await container.transportAdapter.onDisconnect(sessionID: sessionID, clientID: clientID)
                    log.info("Client disconnected: session=\(sessionID.rawValue), landID=\(landID.rawValue)")
                }
            }
        } else {
            logger.info("Client disconnected (was not joined): session=\(sessionID.rawValue)")
        }
    }
    
    // MARK: - Message Handling
    
    /// Called when a message is received from a client.
    ///
    /// Routes the message to the appropriate handler based on message type:
    /// - JoinRequest: Handled by LandRouter
    /// - Other messages: Forwarded to bound TransportAdapter
    ///
    /// - Parameters:
    ///   - message: The raw message data
    ///   - sessionID: The session that sent the message
    public func onMessage(_ message: Data, from sessionID: SessionID) async {
        // Get handshake phase for this session
        let handshakePhase = sessionHandshakePhase[sessionID] ?? .awaitingJoin
        
        do {
            let transportMsg: TransportMessage
            
            // MARK: - Handshake Phase: JSON-only decoding
            if handshakePhase == .awaitingJoin {
                // During handshake, only accept JSON-encoded messages
                guard let firstByte = message.first else {
                    await sendError(
                        to: sessionID,
                        code: .invalidJSON,
                        message: "Empty message received"
                    )
                    return
                }
                
                // Check if message is JSON (starts with { or [)
                if firstByte == 0x7b || firstByte == 0x5b {  // '{' or '['
                    // Try JSON opcode array format first
                    if let json = try? JSONSerialization.jsonObject(with: message),
                       let array = json as? [Any],
                       array.count >= 1,
                       let firstElement = array[0] as? Int,
                       firstElement >= 101 && firstElement <= 106 {
                        // JSON opcode array format
                        transportMsg = try OpcodeTransportMessageDecoder().decode(from: message)
                        
                        if logger.logLevel <= .debug {
                            logger.debug("Handshake: Decoded JSON opcode array format", metadata: [
                                "sessionID": .string(sessionID.rawValue),
                                "opcode": .string("\(firstElement)")
                            ])
                        }
                    } else {
                        // JSON object format
                        let jsonCodec = TransportEncodingConfig.json.makeCodec()
                        transportMsg = try jsonCodec.decode(TransportMessage.self, from: message)
                        
                        if logger.logLevel <= .debug {
                            logger.debug("Handshake: Decoded JSON object format", metadata: [
                                "sessionID": .string(sessionID.rawValue),
                                "kind": .string(transportMsg.kind.rawValue)
                            ])
                        }
                    }
                } else {
                    // Non-JSON format during handshake not allowed
                    await sendError(
                        to: sessionID,
                        code: .invalidJSON,
                        message: "Handshake not completed. Only JSON-encoded join messages are accepted."
                    )
                    return
                }
                
                // During handshake, only process join messages
                guard transportMsg.kind == .join else {
                    await sendError(
                        to: sessionID,
                        code: .joinSessionNotConnected,
                        message: "Not joined. Please send a join request first."
                    )
                    return
                }
                
            // MARK: - Post-Handshake: Use configured encoding
            } else {
                if codec.encoding == .messagepack {
                    // MessagePack codec handles both map and opcode-array formats.
                    transportMsg = try codec.decode(TransportMessage.self, from: message)
                } else if let json = try? JSONSerialization.jsonObject(with: message),
                          let array = json as? [Any],
                          array.count >= 1,
                          let firstElement = array[0] as? Int,
                          firstElement >= 101 && firstElement <= 106
                {
                    // JSON opcode array format
                    if logger.logLevel <= .debug {
                        logger.debug("Detected opcode array format message", metadata: [
                            "sessionID": .string(sessionID.rawValue),
                            "opcode": .string("\(firstElement)")
                        ])
                    }
                    transportMsg = try OpcodeTransportMessageDecoder().decode(from: message)
                } else {
                    // Standard JSON object format
                    transportMsg = try codec.decode(TransportMessage.self, from: message)
                }
            }
            
            // MARK: - Message Routing
            switch transportMsg.kind {
            case .join:
                if case .join(let payload) = transportMsg.payload {
                    do {
                        try await handleJoinRequest(
                            requestID: payload.requestID,
                            landType: payload.landType,
                            landInstanceId: payload.landInstanceId,
                            sessionID: sessionID,
                            requestedPlayerID: payload.playerID,
                            deviceID: payload.deviceID,
                            metadata: payload.metadata
                        )
                    } catch {
                        // Join-domain errors (room creation, replay load, etc.) - not decode failures
                        sessionToBoundLandID.removeValue(forKey: sessionID)
                        // A creation that met a draining instance (or a manager shutdown)
                        // throws a JoinError: answer it like a keeper's join error, so
                        // `landShuttingDown` stays a retryable JOIN_DENIED here too.
                        let (errorCode, errorMessage) = (error as? JoinError).map(Self.joinErrorResponse)
                            ?? (ErrorCode.joinRoomNotFound, "\(error)")
                        await sendJoinError(
                            requestID: payload.requestID,
                            sessionID: sessionID,
                            code: errorCode,
                            message: errorMessage
                        )
                        logger.error("Join failed (land creation or replay load)", metadata: [
                            "sessionID": .string(sessionID.rawValue),
                            "error": .string("\(error)")
                        ])
                    }
                }
                
            default:
                // For all other messages, forward to bound TransportAdapter
                await forwardToTransportAdapter(message: message, sessionID: sessionID, transportMsg: transportMsg)
            }
        } catch {
            logger.error("Failed to decode message", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
            await sendError(
                to: sessionID,
                code: .invalidJSON,
                message: "Failed to decode message: \(error)"
            )
        }
    }
    
    // MARK: - Join Handling
    
    /// Handle a join request from a client.
    ///
    /// - Case A (landInstanceId provided): Join existing land, or create if allowed and doesn't exist
    /// - Case B (landInstanceId nil): Create new land
    private func handleJoinRequest(
        requestID: String,
        landType: String,
        landInstanceId: String?,
        sessionID: SessionID,
        requestedPlayerID: String?,
        deviceID: String?,
        metadata: [String: AnyCodable]?
    ) async throws {
        // Validate session is connected
        guard let clientID = sessionToClient[sessionID] else {
            logger.warning("Join request from unknown session: \(sessionID.rawValue)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinSessionNotConnected,
                message: "Session not connected"
            )
            return
        }
        
        // Check if already joined
        if sessionToBoundLandID[sessionID] != nil {
            logger.warning("Join request from already joined session: \(sessionID.rawValue)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinAlreadyJoined,
                message: "Already joined a land"
            )
            return
        }
        
        // Determine target landID
        let landID: LandID
        let container: LandContainer<State>
        
        if let instanceId = landInstanceId {
            // Case A: Join existing land, or create if allowed and doesn't exist
            landID = LandID(landType: landType, instanceId: instanceId)
            
            if let existingContainer = await landManager.getLand(landID: landID) {
                container = existingContainer
                logger.info("Join existing land: \(landID.rawValue)")
            } else if allowAutoCreateOnJoin {
                // Land doesn't exist, but auto-create is allowed (for demo/testing)
                let definition = landTypeRegistry.getLandDefinition(landType: landType, landID: landID)
                let initialState = landTypeRegistry.initialStateFactory(landType, landID)
                
                container = try await landManager.getOrCreateLand(
                    landID: landID,
                    definition: definition,
                    initialState: initialState,
                    metadata: [:]
                )
                
                logger.info("Land auto-created and joined (allowAutoCreateOnJoin=true)", metadata: [
                    "landID": .string(landID.rawValue),
                    "landType": .string(landType),
                    "sessionID": .string(sessionID.rawValue)
                ])
            } else {
                // Land doesn't exist and auto-create is not allowed (secure default)
                logger.warning("Land not found: \(landID.rawValue)")
                await sendJoinError(
                    requestID: requestID,
                    sessionID: sessionID,
                    code: .joinRoomNotFound,
                    message: "Land not found: \(landID.rawValue)"
                )
                return
            }
            
        } else {
            // Case B: Create new land with auto-generated instanceId
            // SECURITY: Check allowAutoCreateOnJoin before creating new land
            guard allowAutoCreateOnJoin else {
                logger.warning("Join request without instanceId rejected (allowAutoCreateOnJoin=false)", metadata: [
                    "landType": .string(landType),
                    "sessionID": .string(sessionID.rawValue)
                ])
                await sendJoinError(
                    requestID: requestID,
                    sessionID: sessionID,
                    code: .joinDenied,
                    message: "Auto-creation of new lands is disabled. Please specify a landInstanceId to join an existing land."
                )
                return
            }
            
            landID = LandID.generate(landType: landType)
            
            let definition = landTypeRegistry.getLandDefinition(landType: landType, landID: landID)
            let initialState = landTypeRegistry.initialStateFactory(landType, landID)
            
            container = try await landManager.getOrCreateLand(
                landID: landID,
                definition: definition,
                initialState: initialState,
                metadata: [:]
            )
            
            // Note: LandManager already logs "Created new land", so we just log the join context here
            logger.info("New land created and joined", metadata: [
                "landID": .string(landID.rawValue),
                "landType": .string(landType),
                "sessionID": .string(sessionID.rawValue)
            ])
        }
        
        // Bind session to landID
        sessionToBoundLandID[sessionID] = landID
        
        // Prepare PlayerSession using shared helper from TransportAdapter
        let jwtAuthInfo = sessionToAuthInfo[sessionID]
        let playerSession = await container.transportAdapter.preparePlayerSession(
            sessionID: sessionID,
            clientID: clientID,
            requestedPlayerID: requestedPlayerID,
            deviceID: deviceID,
            metadata: metadata,
            authInfo: jwtAuthInfo
        )
        
        // The JoinResponse, built by the adapter from the final playerID and slot. On the
        // in-turn path it is a frame of the join's flip (#69), sent after OnJoin in the commit
        // of a sync phase, directly before the session's firstSync. JSON, as in the handshake.
        let encoding = await container.transportAdapter.getMessageEncoding()
        let joinResponse: @Sendable (PlayerID, Int32) -> Data? = { playerID, playerSlot in
            let response = TransportMessage.joinResponse(
                requestID: requestID,
                success: true,
                landType: landID.landType,
                landInstanceId: landID.instanceId,
                landID: landID.rawValue,
                playerID: playerID.rawValue,
                playerSlot: playerSlot,
                encoding: encoding,
                reason: nil
            )
            return try? TransportEncodingConfig.json.makeMessageEncoder().encode(response)
        }

        // Forward to TransportAdapter for CanJoin/OnJoin handling using shared performJoin.
        //
        // On the in-turn path `performJoin` returns only after the join's flip, and this
        // handler awaits it inline. That relies on a session's inbound being handled serially
        // (the NIO server awaits each frame's `onMessage` before the next): no later frame of
        // this session reaches the router before the phase below is `.joined`, so an action
        // the client sends right after its JoinResponse (or earlier) waits behind the join and
        // is applied after OnJoin. A transport without serial per-session inbound would need a
        // pending-join phase that defers those frames. The session's disconnect waits behind the
        // join too: a client that closes during a slow flip ends in `.timeout`, which cleans up
        // like a disconnect.
        do {
            if let joinResult = try await container.transportAdapter.performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: jwtAuthInfo,
                connectionGeneration: sessionToConnectionGeneration[sessionID],
                joinResponse: joinResponse
            ) {
                if joinResult.completedInTurn {
                    // JoinResponse and firstSync were sent in the flip.
                    sessionHandshakePhase[sessionID] = .joined
                    logger.info("Join successful: session=\(sessionID.rawValue), landID=\(landID.rawValue), playerID=\(joinResult.playerID.rawValue)")
                } else {
                    // IMPORTANT: Send JoinResponse FIRST, then StateSnapshot
                    // This ensures client knows join succeeded before receiving state
                    // Note: initialSyncingPlayers is managed by syncStateForNewPlayer via withInitialSync
                    
                    // 1. Send join response with landType, instanceId, playerSlot, and encoding
                    await sendJoinResponse(
                        requestID: requestID,
                        sessionID: sessionID,
                        success: true,
                        landType: landID.landType,
                        landInstanceId: landID.instanceId,
                        landID: landID.rawValue,
                        playerID: joinResult.playerID.rawValue,
                        playerSlot: joinResult.playerSlot,
                        encoding: encoding,
                        via: container.transportAdapter
                    )
                    
                    // Complete handshake: transition to joined state AFTER sending joinResponse
                    // This ensures joinResponse is sent using JSON encoding (handshake phase)
                    sessionHandshakePhase[sessionID] = .joined
                    
                    // 2. Send initial state snapshot AFTER JoinResponse
                    // syncStateForNewPlayer automatically manages initialSyncingPlayers via withInitialSync
                    await container.transportAdapter.syncStateForNewPlayer(playerID: joinResult.playerID, sessionID: joinResult.sessionID)
                    
                    logger.info("Join successful: session=\(sessionID.rawValue), landID=\(landID.rawValue), playerID=\(joinResult.playerID.rawValue)")
                }
            } else {
                // Join denied
                sessionToBoundLandID.removeValue(forKey: sessionID)
                
                await sendJoinError(
                    requestID: requestID,
                    sessionID: sessionID,
                    code: .joinDenied,
                    message: "Join denied"
                )
                
                logger.warning("Join denied: session=\(sessionID.rawValue)")
            }
        } catch let flipError as JoinFlipError {
            // An in-turn join failed before its flip (#69). On `.disconnected` and `.superseded`
            // the session's own disconnect cleans the adapter up; the other cases clean it up
            // below, before the unbinding hides the session from `onDisconnect`.
            sessionToBoundLandID.removeValue(forKey: sessionID)
            logger.warning("Join failed before it completed", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "reason": .string("\(flipError)"),
            ])
            switch flipError {
            case .disconnected:
                // The client is gone.
                break
            case .superseded:
                // A newer join of the player replaced this session. The error settles this
                // client's pending join before the supersede closes its connection.
                await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinDenied, message: "Join superseded by a newer join of the player")
            case .landClosed:
                await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinDenied, message: "Land is shutting down, retry the join")
            case .timeout, .onJoinFailed, .eventOverflow:
                let (code, message): (ErrorCode, String) = switch flipError {
                case .timeout: (.joinDenied, "Join timed out")
                case .eventOverflow: (.joinEventOverflow, "Too many events were held for the joining session")
                default: (.joinDenied, "Join failed")
                }
                await sendJoinError(requestID: requestID, sessionID: sessionID, code: code, message: message)
                // The adapter's cleanup (membership, slot, joining record, and the keeper's
                // player through `keeper.leave`) runs here, through its membership queue: the
                // session is unbound above, so the disconnect `closeSession` causes doesn't
                // reach the adapter. A retry is a new session.
                await container.transportAdapter.onDisconnect(sessionID: sessionID, clientID: clientID)
                await transport.closeSession(sessionID)
            }
        } catch {
            // Unbind session since join failed
            sessionToBoundLandID.removeValue(forKey: sessionID)
            
            let (errorCode, errorMessage) = (error as? JoinError).map(Self.joinErrorResponse)
                ?? (ErrorCode.joinDenied, "\(error)")
            
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: errorCode,
                message: errorMessage
            )
            
            logger.error("Join failed: session=\(sessionID.rawValue), error=\(error)")
        }
    }
    
    // MARK: - Message Forwarding
    
    /// Forward a message to the bound TransportAdapter.
    private func forwardToTransportAdapter(
        message: Data,
        sessionID: SessionID,
        transportMsg: TransportMessage
    ) async {
        guard let landID = sessionToBoundLandID[sessionID] else {
            logger.warning("Message from session not bound to any land: \(sessionID.rawValue)")
            await sendError(
                to: sessionID,
                code: .joinSessionNotConnected,
                message: "Not joined to any land. Send a join request first."
            )
            return
        }
        
        guard let container = await landManager.getLand(landID: landID) else {
            logger.error("Land not found for bound session: landID=\(landID.rawValue)")
            await sendError(
                to: sessionID,
                code: .joinRoomNotFound,
                message: "Land no longer exists"
            )
            
            // Clean up stale binding
            sessionToBoundLandID.removeValue(forKey: sessionID)
            return
        }
        
        // Forward message to TransportAdapter
        await container.transportAdapter.onMessage(message, from: sessionID)
    }
    
    // MARK: - Response Helpers
    
    /// Send a join response to the client.
    private func sendJoinResponse(
        requestID: String,
        sessionID: SessionID,
        success: Bool,
        landType: String? = nil,
        landInstanceId: String? = nil,
        landID: String? = nil,
        playerID: String? = nil,
        playerSlot: Int32? = nil,
        encoding: String? = nil,
        reason: String? = nil,
        via adapter: TransportAdapter<State>? = nil
    ) async {
        do {
            let response = TransportMessage.joinResponse(
                requestID: requestID,
                success: success,
                landType: landType,
                landInstanceId: landInstanceId,
                landID: landID,
                playerID: playerID,
                playerSlot: playerSlot,
                encoding: encoding,
                reason: reason
            )
            
            // Use JSON encoder for handshake phase, configured encoder after joined
            let handshakePhase = sessionHandshakePhase[sessionID] ?? .awaitingJoin
            let encoder: any TransportMessageEncoder
            if handshakePhase == .awaitingJoin {
                encoder = TransportEncodingConfig.json.makeMessageEncoder()
            } else {
                encoder = messageEncoder
            }
            
            let responseData = try encoder.encode(response)
            if let adapter {
                // Joined: same FIFO as the land's state frames, so it precedes firstSync (#60).
                await adapter.enqueueOutbound(responseData, to: sessionID)
            } else {
                await transport.send(responseData, to: .session(sessionID))
            }
        } catch {
            logger.error("Failed to send join response", metadata: [
                "requestID": .string(requestID),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
    }
    
    /// The error code and message a join error is answered with.
    static func joinErrorResponse(_ joinError: JoinError) -> (ErrorCode, String) {
        switch joinError {
        case .roomIsFull:
            return (.joinRoomFull, "Land is full")
        case .levelTooLow(let required):
            return (.joinDenied, "Level too low (required: \(required))")
        case .banned:
            return (.joinDenied, "You are banned from this land")
        case .custom(let message):
            return (.joinDenied, message)
        case .landShuttingDown:
            // The land started its destruction during this join, or its previous instance has
            // not finished destruction yet: a later join gets a fresh instance for the same ID.
            return (.joinDenied, "Land is shutting down, retry the join")
        }
    }

    /// Send a join error to the client.
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
            
            let errorPayload = ErrorPayload(code: code, message: message, details: errorDetails)
            let errorResponse = TransportMessage.error(errorPayload)
            
            // Use JSON encoder for handshake phase, configured encoder after joined
            let handshakePhase = sessionHandshakePhase[sessionID] ?? .awaitingJoin
            let encoder: any TransportMessageEncoder
            if handshakePhase == .awaitingJoin {
                encoder = TransportEncodingConfig.json.makeMessageEncoder()
            } else {
                encoder = messageEncoder
            }
            
            let errorData = try encoder.encode(errorResponse)
            await deliver(errorData, to: sessionID)
        } catch {
            logger.error("Failed to send join error", metadata: [
                "requestID": .string(requestID),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
    }
    
    /// Send a generic error to the client.
    private func sendError(
        to sessionID: SessionID,
        code: ErrorCode,
        message: String,
        details: [String: AnyCodable]? = nil
    ) async {
        do {
            let errorPayload = ErrorPayload(code: code, message: message, details: details)
            let errorResponse = TransportMessage.error(errorPayload)
            
            // Use JSON encoder for handshake phase, configured encoder after joined
            let handshakePhase = sessionHandshakePhase[sessionID] ?? .awaitingJoin
            let encoder: any TransportMessageEncoder
            if handshakePhase == .awaitingJoin {
                encoder = TransportEncodingConfig.json.makeMessageEncoder()
            } else {
                encoder = messageEncoder
            }
            
            let errorData = try encoder.encode(errorResponse)
            await deliver(errorData, to: sessionID)
        } catch {
            logger.error("Failed to send error", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
    }
    
    /// Sends a router frame. For a session that joined a land, the frame goes through that
    /// land's `TransportAdapter` writer, in order with the land's own frames (#60); during the
    /// handshake it goes to the transport directly.
    private func deliver(_ data: Data, to sessionID: SessionID) async {
        if sessionHandshakePhase[sessionID] == .joined,
           let landID = sessionToBoundLandID[sessionID],
           let container = await landManager.getLand(landID: landID) {
            await container.transportAdapter.enqueueOutbound(data, to: sessionID)
        } else {
            await transport.send(data, to: .session(sessionID))
        }
    }

    // MARK: - Query Methods
    
    /// Check if a session is connected.
    public func isConnected(sessionID: SessionID) -> Bool {
        sessionToClient[sessionID] != nil
    }
    
    /// Check if a session is bound to a land.
    public func isBound(sessionID: SessionID) -> Bool {
        sessionToBoundLandID[sessionID] != nil
    }
    
    /// Get the bound landID for a session.
    public func getBoundLandID(for sessionID: SessionID) -> LandID? {
        sessionToBoundLandID[sessionID]
    }
    
    /// Get all sessions bound to a specific landID.
    public func getSessions(for landID: LandID) -> [SessionID] {
        sessionToBoundLandID.filter { $0.value == landID }.map { $0.key }
    }
}
