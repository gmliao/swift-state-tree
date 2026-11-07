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
        /// The join's request, for the timeout's error (#104).
        var requestID: String = ""
        /// When the join budget runs out (#104); `nil` when disabled.
        var deadline: ContinuousClock.Instant?
        /// The land's adapter, once the attempt is bound to it: the budget then runs out
        /// `waiting for admission`, and the timeout's error goes through that adapter.
        var boundAdapter: TransportAdapter<State>?
        /// The budget's timer, cancelled when the attempt leaves the phase.
        var timer: Task<Void, Never>?
        /// The budget ran out and the router is asking the adapter whether the admission
        /// started (`joinBudgetExpired`): a refused admission's handler leaves the answer to it.
        var expiring = false
        /// The error the join's handler would have answered with, had its admission not
        /// returned (no join, or a throw) while `expiring`: refused because the budget ran
        /// out, denied, or failed. The budget's timeout answers it, either way.
        var unanswered: (code: ErrorCode, message: String)?
        /// Marked by the adapter when the budget's timeout ends the admission before it
        /// started, so the admission is refused when it runs (#242).
        var end = JoinAttemptEnd()
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
    
    /// Tracks handshake phase for each session. Written through `setPhase`, which cancels a
    /// replaced join attempt's budget timer.
    private var sessionHandshakePhase: [SessionID: HandshakePhase] = [:]

    /// Sets (or, with `nil`, removes) the session's phase; a join attempt it replaces loses its
    /// budget timer (#104).
    private func setPhase(_ phase: HandshakePhase?, for sessionID: SessionID) {
        if case .joining(let current) = sessionHandshakePhase[sessionID] {
            var keepsTimer = false
            if case .joining(let next) = phase, next.number == current.number { keepsTimer = next.timer != nil }
            if !keepsTimer { current.timer?.cancel() }
        }
        sessionHandshakePhase[sessionID] = phase
    }

    /// Tests only: replaces `JoinTimeoutConfig.budget`; `.zero` disables it.
    private var joinTimeoutForTesting: Duration?

    /// Error frames the lookup's timeout handed to the transport (tests).
    private(set) var lookupTimeoutFramesForTesting = 0

    /// Expired join budgets checked so far, acted on or not (tests).
    private(set) var joinBudgetChecksForTesting = 0

    /// Tests only: see `joinTimeoutForTesting`.
    func setJoinTimeoutForTesting(_ budget: Duration?) {
        joinTimeoutForTesting = budget
    }

    /// The join budget in effect for a join starting now.
    private var joinBudget: Duration? {
        guard let override = joinTimeoutForTesting else { return JoinTimeoutConfig.budget }
        return override == .zero ? nil : override
    }

    /// The metrics timed-out joins count in (tests may replace it).
    var joinTimeoutMetrics = JoinTimeoutMetrics.shared

    /// Tests only: see `joinTimeoutMetrics`.
    func setJoinTimeoutMetricsForTesting(_ metrics: JoinTimeoutMetrics) {
        joinTimeoutMetrics = metrics
    }
    
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
        JoinTimeoutConfig.warnIfDeprecatedKeySet(resolvedLogger)

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
        setPhase(.awaitingJoin, for: sessionID)  // Initialize handshake state
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
        await holds.at(.disconnectEntry)
        // Get bound landID before cleanup
        let boundLandID = sessionToBoundLandID[sessionID]
        
        // Clean up session state
        sessionToClient.removeValue(forKey: sessionID)
        sessionToConnectionGeneration.removeValue(forKey: sessionID)
        sessionToAuthInfo.removeValue(forKey: sessionID)
        sessionToBoundLandID.removeValue(forKey: sessionID)
        // A join's admission still on its way is refused when it runs (#242): the adapter's
        // ended set alone can evict the session before the admission reaches the queue.
        if case .joining(let current) = sessionHandshakePhase[sessionID] { current.end.markEnded() }
        setPhase(nil, for: sessionID)  // Clean up handshake state (and a join's budget timer)
        
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

        // The client must decode every state-update feature the server's frames use (path
        // indices): an old client would read them as hashes. Checked before any land is created.
        if let missing = TransportAdapter<State>.missingStateUpdateFeatures(
            required: encodingConfig.stateUpdateFeatures, metadata: metadata
        ) {
            logger.warning("Join request without required state-update features", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "missing": .string(missing.joined(separator: ","))
            ])
            await sendJoinError(
                requestID: requestID,
                sessionID: sessionID,
                code: .joinStateUpdateFeatureMissing,
                message: TransportAdapter<State>.missingFeaturesMessage(missing)
            )
            return
        }

        // The attempt starts in the segment of the checks, before the first await.
        lastJoinAttempt += 1
        let attempt = lastJoinAttempt
        // The join budget runs from here, the join request (#104).
        var joinAttempt = JoinAttempt(number: attempt, requestID: requestID)
        if let budget = joinBudget {
            joinAttempt.deadline = .now + budget
            joinAttempt.timer = Task { [weak self] in
                guard (try? await safeTaskSleep(for: budget)) != nil, let router = self else { return }
                await router.joinBudgetExpired(sessionID: sessionID, attempt: attempt)
            }
        }
        setPhase(.joining(joinAttempt), for: sessionID)

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
        if case .joining(var bound) = sessionHandshakePhase[sessionID] {
            bound.boundAdapter = adapter
            sessionHandshakePhase[sessionID] = .joining(bound)
        }

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
        let features = encodingConfig.stateUpdateFeatures
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
                reason: nil,
                stateUpdateFeatures: features.isEmpty ? nil : features
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
                joinAttempt: attempt,
                joinDeadline: joinDeadline(sessionID),
                attemptEnd: attemptEnd(sessionID)
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
            // Admitted in time: the flip waiter has what is left of the budget (#104), so the
            // router's timer stops here.
            let admitted = AdmittedJoin(landID: landID, requestID: requestID, adapter: adapter)
            setPhase(.joining(JoinAttempt(number: attempt, admitted: admitted, requestID: requestID)), for: sessionID)
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
                stateUpdateFeatures: features.isEmpty ? nil : features,
                via: adapter
            )
            await holds.at(.joinResponseSent)
            // The session may have disconnected while the response was sent: its forwarded
            // disconnect, queued after the admission, cleans the adapter up.
            guard isCurrent(sessionID, attempt: attempt) else { return }

            // Complete handshake: transition to joined state AFTER sending joinResponse
            // This ensures joinResponse is sent using JSON encoding (handshake phase)
            setPhase(.joined, for: sessionID)

            // 2. Send initial state snapshot AFTER JoinResponse
            // syncStateForNewPlayer automatically manages initialSyncingPlayers via withInitialSync
            await holds.at(.sendingInitialSync)
            await adapter.syncStateForNewPlayer(playerID: joinResult.playerID, sessionID: joinResult.sessionID)

            logger.info("Join successful: session=\(sessionID.rawValue), landID=\(landID.rawValue), playerID=\(joinResult.playerID.rawValue)")

        case .success(nil):
            // Refused because the budget ran out, or denied, while the budget's timeout waits for
            // the adapter's answer: that timeout answers it (`joinBudgetExpired`).
            if leaveAnswerToExpiry(sessionID, code: .joinDenied, message: "Join denied") { return }
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
            let (errorCode, errorMessage) = (error as? JoinError).map(Self.joinErrorResponse)
                ?? (ErrorCode.joinDenied, "\(error)")
            // As for no join: the budget's timeout, waiting for the adapter, answers it.
            if leaveAnswerToExpiry(sessionID, code: errorCode, message: errorMessage) {
                logger.error("Join failed: session=\(sessionID.rawValue), error=\(error)")
                return
            }
            endAttempt(sessionID)
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
        setPhase(.awaitingJoin, for: sessionID)
    }

    /// The current attempt's `JoinAttemptEnd` (#242), passed to its admission.
    private func attemptEnd(_ sessionID: SessionID) -> JoinAttemptEnd? {
        guard case .joining(let current) = sessionHandshakePhase[sessionID] else { return nil }
        return current.end
    }

    /// The current attempt's budget deadline (#104), passed to the admission for its flip wait.
    private func joinDeadline(_ sessionID: SessionID) -> ContinuousClock.Instant? {
        guard case .joining(let current) = sessionHandshakePhase[sessionID] else { return nil }
        return current.deadline
    }

    /// The join budget ran out (#104). Acts only on the session's current attempt, before the
    /// router saw its admission: an attempt the router saw admitted is left to its flip waiter,
    /// which has what is left of the budget, and an ended or replaced one to whoever ended it.
    ///
    /// - **During the land lookup** (unbound): in the segment of that check, the attempt ends
    ///   and the error, the session's last frame, goes out with the close behind it.
    /// - **Bound, waiting for admission:** where the admission is, is the adapter's to say
    ///   (`endJoinBeforeAdmission`), in one segment of its own. One not started is ended there
    ///   (refused when it runs, the error sent as the last frame) and the attempt then ends
    ///   here. One already in the keeper's join, or done, is left alone, and so is the attempt:
    ///   the join's handler goes on with its outcome. While the router waits for that answer
    ///   the attempt is `expiring`, so a refused admission's handler doesn't answer it.
    ///
    /// A retry is a new session.
    private func joinBudgetExpired(sessionID: SessionID, attempt: UInt64) async {
        await holds.at(.joinBudgetExpired)
        // Same segment as the check (tests: the check has run once this counts it).
        joinBudgetChecksForTesting += 1
        guard case .joining(var current) = sessionHandshakePhase[sessionID],
              current.number == attempt, current.admitted == nil
        else { return }
        // This runs on the timer's task: drop it from the attempt, so the phase changes below
        // don't cancel the task they run on (the closes they start would inherit it).
        current.timer = nil
        sessionHandshakePhase[sessionID] = .joining(current)
        let errorData: (JoinTimeoutPhase) -> Data? = { [requestID = current.requestID] phase in
            self.joinErrorData(requestID: requestID, code: .joinDenied, message: phase.message)
        }
        guard let adapter = current.boundAdapter else {
            // As the adapter's writer sends a final frame: the frame, stamped with the
            // session's connection, then the close behind it.
            let generation = sessionToConnectionGeneration[sessionID]
            endAttempt(sessionID)
            noteJoinTimedOut(.landLookup, sessionID: sessionID, landID: nil)
            if let data = errorData(.landLookup) {
                lookupTimeoutFramesForTesting += 1
                await transport.sendSessionFrames([SessionFrame(data: data, sessionID: sessionID, connectionGeneration: generation)])
            }
            await transport.closeSessionAfterQueuedFrames(sessionID)
            return
        }
        let landID = sessionToBoundLandID[sessionID]
        current.expiring = true
        sessionHandshakePhase[sessionID] = .joining(current)
        let ended = await adapter.endJoinBeforeAdmission(sessionID, finalFrame: errorData(.admission), attemptEnd: current.end)
        guard case .joining(var after) = sessionHandshakePhase[sessionID], after.number == attempt else {
            // Ended meanwhile (a disconnect): its own cleanup reached the adapter.
            if ended { noteJoinTimedOut(.admission, sessionID: sessionID, landID: landID) }
            return
        }
        guard ended else {
            // Admitted, or in the keeper's join: the handler goes on with its outcome. A denial
            // it already returned with is answered here, as the handler would have.
            guard let unanswered = after.unanswered else {
                after.expiring = false
                sessionHandshakePhase[sessionID] = .joining(after)
                return
            }
            endAttempt(sessionID)
            await sendJoinError(requestID: after.requestID, sessionID: sessionID, code: unanswered.code, message: unanswered.message)
            return
        }
        endAttempt(sessionID)
        noteJoinTimedOut(.admission, sessionID: sessionID, landID: landID)
    }

    /// When the session's attempt is `expiring`, records the error its handler would answer
    /// with and returns true: the budget's timeout answers it (`joinBudgetExpired`), so the
    /// client gets one answer. Called only in a segment that checked `isCurrent`.
    private func leaveAnswerToExpiry(_ sessionID: SessionID, code: ErrorCode, message: String) -> Bool {
        guard case .joining(var current) = sessionHandshakePhase[sessionID], current.expiring else { return false }
        current.unanswered = (code, message)
        sessionHandshakePhase[sessionID] = .joining(current)
        return true
    }

    private func noteJoinTimedOut(_ phase: JoinTimeoutPhase, sessionID: SessionID, landID: LandID?) {
        joinTimeoutMetrics.noteTimedOut(phase)
        logger.warning("Join timed out", metadata: [
            "sessionID": .string(sessionID.rawValue),
            "phase": .string(phase.phrase),
            "landID": .string(landID?.rawValue ?? "-"),
        ])
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
            setPhase(.joined, for: sessionID)
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
        logger.warning(failure == .timeout ? "Join timed out" : "Join failed before it completed", metadata: [
            "sessionID": .string(sessionID.rawValue),
            "reason": .string("\(failure)"),
            "phase": .string(failure == .timeout ? JoinTimeoutPhase.flip.phrase : "-"),
        ])
        let requestID = pending.requestID
        if case .timeout = failure { joinTimeoutMetrics.noteTimedOut(.flip) }
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
            case .timeout: (.joinDenied, JoinTimeoutPhase.flip.message)
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
        stateUpdateFeatures: [String]? = nil,
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
                reason: reason,
                stateUpdateFeatures: stateUpdateFeatures
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
    /// The join budget's timer fired, before it checks the attempt (#104).
    case joinBudgetExpired
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
    /// A disconnect on arrival at the router, before it reads or changes the session's state.
    case disconnectEntry
}
