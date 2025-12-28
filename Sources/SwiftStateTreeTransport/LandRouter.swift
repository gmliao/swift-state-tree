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
    private let codec: any TransportCodec
    
    // MARK: - Session Management
    
    /// Maps sessionID to clientID for connected sessions
    private var sessionToClient: [SessionID: ClientID] = [:]
    
    /// Maps sessionID to bound landID after successful join
    private var sessionToBoundLandID: [SessionID: LandID] = [:]
    
    /// Maps sessionID to auth info (from JWT or other auth mechanisms)
    private var sessionToAuthInfo: [SessionID: AuthenticatedInfo] = [:]
    
    /// Guest session factory (optional)
    private let createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)?
    
    // MARK: - Initialization
    
    /// Initialize a LandRouter.
    ///
    /// - Parameters:
    ///   - landManager: Manager for Land instances
    ///   - landTypeRegistry: Registry for landType → LandDefinition mapping
    ///   - transport: WebSocket transport for sending messages
    ///   - createGuestSession: Optional factory for creating guest sessions
    ///   - logger: Optional logger instance
    public init(
        landManager: LandManager<State>,
        landTypeRegistry: LandTypeRegistry<State>,
        transport: WebSocketTransport,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        codec: any TransportCodec = JSONTransportCodec(),
        logger: Logger? = nil
    ) {
        self.landManager = landManager
        self.landTypeRegistry = landTypeRegistry
        self.transport = transport
        self.createGuestSession = createGuestSession
        self.codec = codec
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.transport",
            scope: "LandRouter"
        )
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
        sessionToAuthInfo.removeValue(forKey: sessionID)
        sessionToBoundLandID.removeValue(forKey: sessionID)
        
        // If session was bound to a land, notify the TransportAdapter
        if let landID = boundLandID {
            if let container = await landManager.getLand(landID: landID) {
                await container.transportAdapter.onDisconnect(sessionID: sessionID, clientID: clientID)
                logger.info("Client disconnected: session=\(sessionID.rawValue), landID=\(landID.rawValue)")
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
        do {
            let transportMsg = try codec.decode(TransportMessage.self, from: message)
            
            switch transportMsg.kind {
            case .join:
                if case .join(let payload) = transportMsg.payload {
                    await handleJoinRequest(
                        requestID: payload.requestID,
                        landType: payload.landType,
                        landInstanceId: payload.landInstanceId,
                        sessionID: sessionID,
                        requestedPlayerID: payload.playerID,
                        deviceID: payload.deviceID,
                        metadata: payload.metadata
                    )
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
    /// - Case A (landInstanceId provided): Join existing land
    /// - Case B (landInstanceId nil): Create new land
    private func handleJoinRequest(
        requestID: String,
        landType: String,
        landInstanceId: String?,
        sessionID: SessionID,
        requestedPlayerID: String?,
        deviceID: String?,
        metadata: [String: AnyCodable]?
    ) async {
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
            // Case A: Join existing land
            landID = LandID(landType: landType, instanceId: instanceId)
            
            guard let existingContainer = await landManager.getLand(landID: landID) else {
                logger.warning("Land not found: \(landID.rawValue)")
                await sendJoinError(
                    requestID: requestID,
                    sessionID: sessionID,
                    code: .joinRoomNotFound,
                    message: "Land not found: \(landID.rawValue)"
                )
                return
            }
            
            container = existingContainer
            logger.info("Join existing land: \(landID.rawValue)")
            
        } else {
            // Case B: Create new land
            landID = LandID.generate(landType: landType)
            
            let definition = landTypeRegistry.getLandDefinition(landType: landType, landID: landID)
            let initialState = landTypeRegistry.initialStateFactory(landType, landID)
            
            container = await landManager.getOrCreateLand(
                landID: landID,
                definition: definition,
                initialState: initialState
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
        
        // Forward to TransportAdapter for CanJoin/OnJoin handling using shared performJoin
        do {
            if let joinResult = try await container.transportAdapter.performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: jwtAuthInfo
            ) {
                // IMPORTANT: Send JoinResponse FIRST, then StateSnapshot
                // This ensures client knows join succeeded before receiving state
                
                // 1. Send join response with landType and instanceId
                await sendJoinResponse(
                    requestID: requestID,
                    sessionID: sessionID,
                    success: true,
                    landType: landID.landType,
                    landInstanceId: landID.instanceId,
                    landID: landID.rawValue,
                    playerID: joinResult.playerID.rawValue
                )
                
                // 2. Send initial state snapshot AFTER JoinResponse
                await container.transportAdapter.sendInitialSnapshot(for: joinResult)
                
                logger.info("Join successful: session=\(sessionID.rawValue), landID=\(landID.rawValue), playerID=\(joinResult.playerID.rawValue)")
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
        } catch {
            // Unbind session since join failed
            sessionToBoundLandID.removeValue(forKey: sessionID)
            
            let errorCode: ErrorCode
            let errorMessage: String
            
            if let joinError = error as? JoinError {
                switch joinError {
                case .roomIsFull:
                    errorCode = .joinRoomFull
                    errorMessage = "Land is full"
                case .levelTooLow(let required):
                    errorCode = .joinDenied
                    errorMessage = "Level too low (required: \(required))"
                case .banned:
                    errorCode = .joinDenied
                    errorMessage = "You are banned from this land"
                case .custom(let message):
                    errorCode = .joinDenied
                    errorMessage = message
                }
            } else {
                errorCode = .joinDenied
                errorMessage = "\(error)"
            }
            
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
        reason: String? = nil
    ) async {
        do {
            let response = TransportMessage.joinResponse(
                requestID: requestID,
                success: success,
                landType: landType,
                landInstanceId: landInstanceId,
                landID: landID,
                playerID: playerID,
                reason: reason
            )
            let responseData = try codec.encode(response)
            try await transport.send(responseData, to: .session(sessionID))
        } catch {
            logger.error("Failed to send join response", metadata: [
                "requestID": .string(requestID),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
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
            let errorData = try codec.encode(errorResponse)
            try await transport.send(errorData, to: .session(sessionID))
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
            let errorData = try codec.encode(errorResponse)
            try await transport.send(errorData, to: .session(sessionID))
        } catch {
            logger.error("Failed to send error", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
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
