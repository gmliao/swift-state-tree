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
    /// See `init(authenticatesPlayers:)`.
    private let authenticatesPlayers: Bool
    
    // MARK: - Handshake State Machine
    
    /// Handshake phase for managing join protocol
    private enum HandshakePhase {
        case awaitingJoin    // Waiting for join (only accepts JSON join)
        /// A join in progress (#97, #99): set in the segment of the join's checks, before its
        /// first await, and held until the join ends. A second join meanwhile gets
        /// `JOIN_IN_PROGRESS`. Once an in-turn join is admitted (`JoinAttempt.admitted`, #69),
        /// frames are decoded with the configured encoding and go to the land's adapter, which
        /// defers them until after OnJoin.
        case joining(JoinAttempt)
        case joined          // Handshake completed (uses configured encoding)

        /// Frames are decoded as in the handshake: JSON only.
        var decodesAsHandshake: Bool {
            switch self {
            case .awaitingJoin: true
            case .joining(let attempt): attempt.admitted == nil
            case .joined: false
            }
        }
    }

    /// A join in progress.
    ///
    /// **Its ticket is `number`.** Every router write after one of the join's awaits happens in
    /// a segment that first checks the phase still holds this attempt (`isCurrent`). The phase
    /// goes in `onDisconnect`, and a later join of the same session is a new number, so the
    /// check fails for an attempt whose session ended or that was replaced. With one
    /// `SessionID` per connection (the transport rejects a held ID), the phase entry belongs to
    /// one connection, and a per-session `GenerationTable` ticket would carry nothing the
    /// number doesn't. `isCurrent` is the one place to change if one is wanted.
    private struct JoinAttempt {
        let number: UInt64
        /// Set once an in-turn join is admitted: it waits for its flip (#69).
        var admitted: AdmittedJoin?
    }

    /// An in-turn join admitted to a land's adapter, waiting for its flip (#69).
    private struct AdmittedJoin {
        let landID: LandID
        let requestID: String
        let adapter: TransportAdapter<State>
    }

    /// The last join attempt number issued (`JoinAttempt.number`).
    private var lastJoinAttempt: UInt64 = 0

    /// Forced-interleaving hold points (tests only; a no-op unless installed).
    private var holds = HoldPoints<LandRouterHoldPoint>()

    /// Installs (or, with `nil`, removes) the hold hook (tests).
    func installHolds(_ hook: (@Sendable (LandRouterHoldPoint) async -> Void)?) {
        holds.install(hook)
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
    ///   - authenticatesPlayers: The land type authenticates players (a JWT validator or
    ///     configuration is set): a session without a token can't name a `playerID` (#209).
    ///     The default, `false`, fails open: a router constructed directly lets a tokenless
    ///     session name any `playerID`, so pass `true` whenever the land authenticates players.
    ///   - allowAutoCreateOnJoin: Allow auto-creating land when join with instanceId but land doesn't exist (default: false)
    ///   - logger: Optional logger instance
    public init(
        landManager: LandManager<State>,
        landTypeRegistry: LandTypeRegistry<State>,
        transport: WebSocketTransport,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        authenticatesPlayers: Bool = false,
        allowAutoCreateOnJoin: Bool = false,
        transportEncoding: TransportEncodingConfig = .jsonOpcode,
        logger: Logger? = nil
    ) {
        self.landManager = landManager
        self.landTypeRegistry = landTypeRegistry
        self.transport = transport
        self.createGuestSession = createGuestSession
        self.authenticatesPlayers = authenticatesPlayers
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
                let holds = self.holds
                Task {
                    await container.transportAdapter.onDisconnect(sessionID: sessionID, clientID: clientID)
                    await holds.at(.disconnectForwarded)
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
            if handshakePhase.decodesAsHandshake {
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
    /// - Case A (landInstanceId provided): Join existing land, or create if allowed and doesn't exist
    /// - Case B (landInstanceId nil): Create new land
    ///
    /// The join is one attempt (`JoinAttempt`, #97, #99): the phase is `.joining` from the
    /// segment of the checks on, and every router write after an await first checks that the
    /// attempt is still current. A stale attempt (its session disconnected) writes nothing and
    /// sends nothing; only the adapter cleanup of an admission it may have caused is its own.
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

        // One join at a time: a join in progress answers a second one with its own code.
        if case .joining = sessionHandshakePhase[sessionID] {
            logger.warning("Join request while a join is in progress: \(sessionID.rawValue)")
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinInProgress,
                message: "A join is already in progress"
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

        // An authenticated session joins as its token's player; on a land that authenticates
        // players, a session without a token can't name one (#209). Checked before any land is
        // looked up or created.
        if let rejection = TransportAdapter<State>.joinIdentityRejection(
            requestedPlayerID: requestedPlayerID,
            authInfo: sessionToAuthInfo[sessionID],
            authenticatesPlayers: authenticatesPlayers
        ) {
            rejection.log(logger, sessionID: sessionID, requestedPlayerID: requestedPlayerID)
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinPlayerMismatch,
                message: rejection.message
            )
            return
        }

        // The attempt starts in the segment of the checks, before the first await.
        lastJoinAttempt += 1
        let attempt = lastJoinAttempt
        sessionHandshakePhase[sessionID] = .joining(JoinAttempt(number: attempt))

        // Determine target landID
        let landID: LandID
        let container: LandContainer<State>
        do {
            guard let found = try await lookUpLand(landType: landType, landInstanceId: landInstanceId, sessionID: sessionID) else {
                // Not found, or creation not allowed: answered below if still current.
                guard isCurrent(sessionID, attempt: attempt) else { return }
                endAttempt(sessionID)
                let (code, message) = landInstanceId.map { (ErrorCode.joinRoomNotFound, "Land not found: \(LandID(landType: landType, instanceId: $0).rawValue)") }
                    ?? (ErrorCode.joinDenied, "Auto-creation of new lands is disabled. Please specify a landInstanceId to join an existing land.")
                await sendJoinError(requestID: requestID, sessionID: sessionID, code: code, message: message)
                return
            }
            (landID, container) = found
        } catch {
            // Join-domain errors (room creation, replay load, etc.). A creation that met a
            // draining instance (or a manager shutdown) throws a JoinError: answer it like a
            // keeper's join error, so `landShuttingDown` stays a retryable JOIN_DENIED here too.
            guard isCurrent(sessionID, attempt: attempt) else { return }
            endAttempt(sessionID)
            let (errorCode, errorMessage) = (error as? JoinError).map(Self.joinErrorResponse)
                ?? (ErrorCode.joinRoomNotFound, "\(error)")
            await sendJoinError(requestID: requestID, sessionID: sessionID, code: errorCode, message: errorMessage)
            logger.error("Join failed (land creation or replay load)", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
            return
        }
        await holds.at(.afterLand)

        // A session that disconnected during the lookup gets no binding (a land created only
        // for it has no players, and its destroy-when-empty timer removes it).
        guard isCurrent(sessionID, attempt: attempt) else { return }
        // Bind session to landID, so a disconnect from here on is forwarded to the adapter.
        sessionToBoundLandID[sessionID] = landID
        let adapter = container.transportAdapter

        // Prepare PlayerSession using shared helper from TransportAdapter
        let jwtAuthInfo = sessionToAuthInfo[sessionID]
        let connectionGeneration = sessionToConnectionGeneration[sessionID]
        let playerSession = await adapter.preparePlayerSession(
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
        let encoding = await adapter.getMessageEncoding()
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
        await holds.at(.beforeAdmit)

        // A stale attempt isn't admitted: its admission could supersede the player's newer
        // connection (another SessionID that joined meanwhile), which no cleanup undoes.
        guard isCurrent(sessionID, attempt: attempt) else { return }

        // Forward to TransportAdapter for CanJoin/OnJoin handling. `admitJoin` returns after the
        // admission. A join that completes in a turn (#69) then waits for its flip in a Task of
        // the router's own (`awaitFlip`), so this handler returns and the session's next frames
        // reach the adapter, which defers them until after OnJoin. That the next frame can't
        // arrive before the admission relies on serial per-session delivery: the NIO server
        // awaits each frame's `onMessage` before the next.
        let admission: Result<TransportAdapter<State>.JoinResult?, any Error>
        do {
            admission = .success(try await adapter.admitJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: jwtAuthInfo,
                connectionGeneration: connectionGeneration,
                joinResponse: joinResponse,
                joinAttempt: attempt
            ))
        } catch {
            admission = .failure(error)
        }
        await holds.at(.afterAdmit)

        guard isCurrent(sessionID, attempt: attempt) else {
            // The session disconnected after the check above, while the admission was on its
            // way. Its forwarded disconnect may have reached the adapter before this admission
            // was queued, as a no-op: the admission is then this join's to undo, whatever its
            // outcome. Idempotent, so a disconnect that came after the admission makes it a
            // no-op.
            await adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
            return
        }

        switch admission {
        case .success(let joinResult?) where joinResult.completedInTurn:
            // JoinResponse and firstSync are sent in the flip.
            let admitted = AdmittedJoin(landID: landID, requestID: requestID, adapter: adapter)
            sessionHandshakePhase[sessionID] = .joining(JoinAttempt(number: attempt, admitted: admitted))
            let playerID = joinResult.playerID
            Task { await self.awaitFlip(attempt: attempt, admitted, sessionID: sessionID, clientID: clientID, playerID: playerID) }

        case .success(let joinResult?):
            // IMPORTANT: Send JoinResponse FIRST, then StateSnapshot
            // This ensures client knows join succeeded before receiving state
            // Note: initialSyncingPlayers is managed by syncStateForNewPlayer via withInitialSync

            // 1. Send join response with landType, instanceId, playerSlot, and encoding
            await holds.at(.sendingJoinResponse)
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
                via: adapter
            )
            await holds.at(.joinResponseSent)
            // The session may have disconnected while the response was sent: its forwarded
            // disconnect, queued after the admission, cleans the adapter up.
            guard isCurrent(sessionID, attempt: attempt) else { return }

            // Complete handshake: transition to joined state AFTER sending joinResponse
            // This ensures joinResponse is sent using JSON encoding (handshake phase)
            sessionHandshakePhase[sessionID] = .joined

            // 2. Send initial state snapshot AFTER JoinResponse
            // syncStateForNewPlayer automatically manages initialSyncingPlayers via withInitialSync
            await holds.at(.sendingInitialSync)
            await adapter.syncStateForNewPlayer(playerID: joinResult.playerID, sessionID: joinResult.sessionID)

            logger.info("Join successful: session=\(sessionID.rawValue), landID=\(landID.rawValue), playerID=\(joinResult.playerID.rawValue)")

        case .success(nil):
            // Join denied
            endAttempt(sessionID)
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinDenied,
                message: "Join denied"
            )
            logger.warning("Join denied: session=\(sessionID.rawValue)")

        case .failure(let error):
            endAttempt(sessionID)
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

    /// The land a join goes to: an existing one, or a new one where creation is allowed. `nil`
    /// when it doesn't exist and may not be created.
    private func lookUpLand(landType: String, landInstanceId: String?, sessionID: SessionID) async throws -> (LandID, LandContainer<State>)? {
        if let instanceId = landInstanceId {
            // Case A: Join existing land, or create if allowed and doesn't exist
            let landID = LandID(landType: landType, instanceId: instanceId)
            if let existing = await landManager.getLand(landID: landID) {
                logger.info("Join existing land: \(landID.rawValue)")
                return (landID, existing)
            }
            guard allowAutoCreateOnJoin else {
                // Land doesn't exist and auto-create is not allowed (secure default)
                logger.warning("Land not found: \(landID.rawValue)")
                return nil
            }
            // Land doesn't exist, but auto-create is allowed (for demo/testing)
            let container = try await landManager.getOrCreateLand(
                landID: landID,
                definition: landTypeRegistry.getLandDefinition(landType: landType, landID: landID),
                initialState: landTypeRegistry.initialStateFactory(landType, landID),
                metadata: [:]
            )
            logger.info("Land auto-created and joined (allowAutoCreateOnJoin=true)", metadata: [
                "landID": .string(landID.rawValue),
                "landType": .string(landType),
                "sessionID": .string(sessionID.rawValue)
            ])
            return (landID, container)
        }

        // Case B: Create new land with auto-generated instanceId
        // SECURITY: Check allowAutoCreateOnJoin before creating new land
        guard allowAutoCreateOnJoin else {
            logger.warning("Join request without instanceId rejected (allowAutoCreateOnJoin=false)", metadata: [
                "landType": .string(landType),
                "sessionID": .string(sessionID.rawValue)
            ])
            return nil
        }
        let landID = LandID.generate(landType: landType)
        let container = try await landManager.getOrCreateLand(
            landID: landID,
            definition: landTypeRegistry.getLandDefinition(landType: landType, landID: landID),
            initialState: landTypeRegistry.initialStateFactory(landType, landID),
            metadata: [:]
        )
        // Note: LandManager already logs "Created new land", so we just log the join context here
        logger.info("New land created and joined", metadata: [
            "landID": .string(landID.rawValue),
            "landType": .string(landType),
            "sessionID": .string(sessionID.rawValue)
        ])
        return (landID, container)
    }

    /// Whether `attempt` is still the session's join in progress: the ticket check every router
    /// write after one of the join's awaits makes (`JoinAttempt`).
    private func isCurrent(_ sessionID: SessionID, attempt: UInt64) -> Bool {
        guard case .joining(let current) = sessionHandshakePhase[sessionID] else { return false }
        return current.number == attempt
    }

    /// Ends the session's current join attempt without a join: unbound, awaiting a join again.
    /// Called only in a segment that checked `isCurrent`.
    private func endAttempt(_ sessionID: SessionID) {
        sessionToBoundLandID.removeValue(forKey: sessionID)
        sessionHandshakePhase[sessionID] = .awaitingJoin
    }

    /// The flip wait of an in-turn join (#69), in a router-owned Task. Every write here happens
    /// in a segment that first checks the attempt is still current: a session that
    /// disconnected meanwhile is left alone, since its own disconnect already cleaned the
    /// adapter up.
    private func awaitFlip(attempt: UInt64, _ pending: AdmittedJoin, sessionID: SessionID, clientID: ClientID, playerID: PlayerID) async {
        let failure: JoinFlipError
        do {
            try await pending.adapter.awaitJoined(sessionID: sessionID)
            await holds.at(.flipWaitResumed)
            guard isCurrent(sessionID, attempt: attempt) else { return }
            sessionHandshakePhase[sessionID] = .joined
            logger.info("Join successful: session=\(sessionID.rawValue), landID=\(pending.landID.rawValue), playerID=\(playerID.rawValue)")
            return
        } catch let flipError as JoinFlipError {
            failure = flipError
        } catch {
            failure = .onJoinFailed
        }
        guard isCurrent(sessionID, attempt: attempt) else { return }
        // Same segment as the check: unbind, so the disconnect the close causes doesn't reach
        // the adapter again; the cases below clean it up themselves.
        endAttempt(sessionID)
        logger.warning("Join failed before it completed", metadata: [
            "sessionID": .string(sessionID.rawValue),
            "reason": .string("\(failure)"),
        ])
        let requestID = pending.requestID
        switch failure {
        case .disconnected:
            // The client is gone.
            break
        case .superseded:
            // A newer join of the player replaced this session. The error settles this
            // client's pending join before the supersede closes its connection.
            await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinDenied, message: "Join superseded by a newer join of the player")
        case .landClosed:
            await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinDenied, message: "Land is shutting down, retry the join")
        case .timeout, .onJoinFailed, .eventOverflow, .inboundOverflow:
            let (code, message): (ErrorCode, String) = switch failure {
            case .timeout: (.joinDenied, "Join timed out")
            case .eventOverflow: (.joinEventOverflow, "Too many events were held for the joining session")
            case .inboundOverflow: (.joinInboundOverflow, "Too many frames were sent before the join completed")
            default: (.joinDenied, "Join failed")
            }
            // The error is the session's last frame: it goes through the adapter's writer with
            // the close behind it, so the close can't overtake it (handed to the connection
            // within `JoinFlipConfig.finalFrameCloseTimeout`).
            if let errorData = joinErrorData(requestID: requestID, code: code, message: message) {
                await pending.adapter.sendFinalFrameAndClose(errorData, to: sessionID)
            } else {
                await transport.closeSession(sessionID)
            }
            // The adapter's cleanup (membership, slot, joining record, and the keeper's player
            // through `keeper.leave`) runs here, through its membership queue: the session is
            // unbound above, so the disconnect the close causes doesn't reach the adapter. A
            // retry is a new session.
            await pending.adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
        }
    }

    /// Whether the session's in-turn join is admitted and waiting for its flip (tests).
    func isJoinPending(_ sessionID: SessionID) -> Bool {
        guard case .joining(let attempt) = sessionHandshakePhase[sessionID] else { return false }
        return attempt.admitted != nil
    }

    /// Whether the session has a join in progress, admitted or not (tests).
    func isJoining(_ sessionID: SessionID) -> Bool {
        guard case .joining = sessionHandshakePhase[sessionID] else { return false }
        return true
    }

    /// Whether the router holds a handshake phase for the session (tests): none after its
    /// disconnect.
    func hasHandshakePhase(_ sessionID: SessionID) -> Bool {
        sessionHandshakePhase[sessionID] != nil
    }

    /// A join error frame, JSON as in the handshake: the client hasn't had its JoinResponse.
    private func joinErrorData(requestID: String, code: ErrorCode, message: String) -> Data? {
        let payload = ErrorPayload(code: code, message: message, details: ["requestID": AnyCodable(requestID)])
        return try? TransportEncodingConfig.json.makeMessageEncoder().encode(TransportMessage.error(payload))
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
            if handshakePhase.decodesAsHandshake {
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
            if handshakePhase.decodesAsHandshake {
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
            if handshakePhase.decodesAsHandshake {
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
        if case .joining(let attempt) = sessionHandshakePhase[sessionID], let pending = attempt.admitted {
            // In order with the land's own frames, through the writer the flip sends through.
            // Before the flip that puts it ahead of the JoinResponse, encoded with the land's
            // encoder while the client still expects JSON (MessagePack on a MessagePack land).
            // Only a misbehaving client gets a router frame then: a second join
            // (`joinAlreadyJoined`) or an undecodable frame.
            await pending.adapter.enqueueOutbound(data, to: sessionID)
        } else if case .joined = sessionHandshakePhase[sessionID],
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

/// Points where a test can hold the router (`LandRouter.installHolds`).
enum LandRouterHoldPoint: Hashable, Sendable {
    /// A flip wait after its join flipped (the JoinResponse is sent), before the phase becomes
    /// `.joined` (#69).
    case flipWaitResumed
    /// A join after its land was looked up or created, before the attempt binds the session
    /// (#97).
    case afterLand
    /// A join after its binding, right before `admitJoin` is called (#97).
    case beforeAdmit
    /// A join after `admitJoin` returned (or threw), before the attempt is checked (#97).
    case afterAdmit
    /// An off-path join right before it sends its JoinResponse (#97).
    case sendingJoinResponse
    /// An off-path join after its JoinResponse was sent, before `.joined` (#97).
    case joinResponseSent
    /// An off-path join right before it starts the session's initial sync (#97).
    case sendingInitialSync
    /// A disconnect after the adapter handled the router's forward of it (#97).
    case disconnectForwarded
}
