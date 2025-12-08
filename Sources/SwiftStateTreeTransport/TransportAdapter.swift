import Foundation
import SwiftStateTree
import Logging

/// Adapts Transport events to LandKeeper calls.
public actor TransportAdapter<State: StateNodeProtocol>: TransportDelegate {
    
    private let keeper: LandKeeper<State>
    private let transport: WebSocketTransport
    private let landID: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var syncEngine = SyncEngine()
    private let logger: Logger
    
    // Track session to player mapping
    private var sessionToPlayer: [SessionID: PlayerID] = [:]
    private var sessionToClient: [SessionID: ClientID] = [:]
    // Track JWT payload information for each session
    private var sessionToAuthInfo: [SessionID: AuthenticatedInfo] = [:]
    
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
    /// Default implementation creates guest session with "guest-{randomID}" as playerID.
    public var createGuestSession: @Sendable (SessionID, ClientID) -> PlayerSession = { sessionID, clientID in
        // Generate short random ID (6 characters)
        let randomID = String(UUID().uuidString.prefix(6))
        return PlayerSession(
            playerID: "guest-\(randomID)",
            deviceID: clientID.rawValue,
            metadata: ["isGuest": "true"]
        )
    }
    
    public init(
        keeper: LandKeeper<State>,
        transport: WebSocketTransport,
        landID: String,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        logger: Logger? = nil
    ) {
        self.keeper = keeper
        self.transport = transport
        self.landID = landID
        // Create logger with scope if not provided
        if let logger = logger {
            self.logger = logger.withScope("TransportAdapter")
        } else {
            self.logger = createColoredLogger(
                loggerIdentifier: "com.swiftstatetree.transport",
                scope: "TransportAdapter"
            )
        }
        if let createGuestSession = createGuestSession {
            self.createGuestSession = createGuestSession
        }
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
            // Remove from sessionToPlayer BEFORE calling keeper.leave()
            // This ensures syncBroadcastOnly() only sends to remaining players
            sessionToPlayer.removeValue(forKey: sessionID)
            
            // Now call keeper.leave() which will trigger syncBroadcastOnly()
            // syncBroadcastOnly() will only see remaining players in sessionToPlayer
            await keeper.leave(playerID: playerID, clientID: clientID)
            
            // Clear syncEngine cache for disconnected player
            // This ensures reconnection behaves like first connection
            syncEngine.clearCacheForDisconnectedPlayer(playerID)
        
        logger.info("Client disconnected: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
        } else {
            logger.info("Client disconnected (was not joined): session=\(sessionID.rawValue)")
        }
    }
    
    public func onMessage(_ message: Data, from sessionID: SessionID) async {
        let messageSize = message.count
        let messagePreview = String(data: message, encoding: .utf8) ?? "<non-UTF8 payload>"
        
        logger.debug("📥 Received message", metadata: [
            "session": .string(sessionID.rawValue),
            "bytes": .string("\(messageSize)")
        ])
        
        logger.trace("📥 Message payload", metadata: [
            "session": .string(sessionID.rawValue),
            "payload": .string(messagePreview)
        ])
        
        do {
            let transportMsg = try decoder.decode(TransportMessage.self, from: message)
            
            switch transportMsg {
            case .join(let requestID, let landID, let requestedPlayerID, let deviceID, let metadata):
                // Handle join request (can be sent before player is joined)
                await handleJoinRequest(
                    requestID: requestID,
                    landID: landID,
                    sessionID: sessionID,
                    requestedPlayerID: requestedPlayerID,
                    deviceID: deviceID,
                    metadata: metadata
                )
                return
                
            case .joinResponse:
                // Server should not receive joinResponse from client
                logger.warning("Received joinResponse from client (unexpected)", metadata: [
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
            
            switch transportMsg {
            case .action(let requestID, let landID, let envelope):
                logger.info("📥 Received action", metadata: [
                    "requestID": .string(requestID),
                    "landID": .string(landID),
                    "actionType": .string(envelope.typeIdentifier),
                    "playerID": .string(playerID.rawValue),
                    "sessionID": .string(sessionID.rawValue)
                ])
                
                // Decode action payload if possible
                if let payloadString = String(data: envelope.payload, encoding: .utf8) {
                    logger.trace("📥 Action payload", metadata: [
                        "requestID": .string(requestID),
                        "payload": .string(payloadString)
                    ])
                }
                
                // TODO: Decode action based on typeIdentifier and call keeper
                _ = requestID
                _ = landID
                
                case .actionResponse(let requestID, let response):
                    logger.info("📥 Received action response", metadata: [
                        "requestID": .string(requestID),
                        "playerID": .string(playerID.rawValue),
                        "sessionID": .string(sessionID.rawValue)
                    ])
                    
                    // Log response payload
                    if let responseData = try? encoder.encode(response),
                       let responseString = String(data: responseData, encoding: .utf8) {
                        logger.trace("📥 Response payload", metadata: [
                            "requestID": .string(requestID),
                            "response": .string(responseString)
                        ])
                    }
                
            case .event(let landID, let eventWrapper):
                if case .fromClient(let anyClientEvent) = eventWrapper {
                    logger.info("📥 Received client event", metadata: [
                        "landID": .string(landID),
                        "eventType": .string(anyClientEvent.type),
                        "playerID": .string(playerID.rawValue),
                        "sessionID": .string(sessionID.rawValue)
                    ])
                    
                    // Log event payload
                    if let payloadData = try? encoder.encode(anyClientEvent.payload),
                       let payloadString = String(data: payloadData, encoding: .utf8) {
                        logger.trace("📥 Event payload", metadata: [
                            "eventType": .string(anyClientEvent.type),
                            "payload": .string(payloadString)
                        ])
                    }
                    
                    await keeper.handleClientEvent(
                        anyClientEvent,
                        playerID: playerID,
                        clientID: clientID,
                        sessionID: sessionID
                    )
                } else if case .fromServer = eventWrapper {
                    logger.warning("Received server event from client (unexpected)", metadata: [
                        "sessionID": .string(sessionID.rawValue)
                    ])
                }
                
                case .join, .joinResponse:
                    // Already handled above
                    break
                }
            }
        } catch {
            logger.error("❌ Failed to decode message", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)"),
                "payload": .string(messagePreview)
            ])
        }
    }
    
    // MARK: - Helper Methods
    
    /// Send server event to specified target
    public func sendEvent(_ event: AnyServerEvent, to target: SwiftStateTree.EventTarget) async {
        do {
            let transportMsg = TransportMessage.event(
                landID: landID,
                event: .fromServer(event)
            )
            
            let data = try encoder.encode(transportMsg)
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
                "bytes": .string("\(dataSize)")
            ])
            
            // Log event payload
            if let payloadString = String(data: try encoder.encode(event.payload), encoding: .utf8) {
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
        
        // Extract broadcast snapshot once and reuse for all players
        do {
            let state = await keeper.currentState()
            
            // Extract broadcast snapshot once (shared across all players)
            let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
            
            // Sync state for all connected players using shared broadcast snapshot
            // Note: syncState() doesn't throw, but transport.send() inside it might fail
            // We handle errors inside syncState() to avoid one failure stopping all updates
        for (sessionID, playerID) in sessionToPlayer {
                await syncState(
                    for: playerID,
                    sessionID: sessionID,
                    state: state,
                    broadcastSnapshot: broadcastSnapshot
                )
            }
        } catch {
            logger.error("❌ Failed to extract broadcast snapshot", metadata: [
                "error": .string("\(error)")
            ])
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
    public func syncBroadcastOnly() async {
        // Note: Even if no players are connected, we still need to update the broadcast cache
        // This ensures that when a player reconnects, they see the correct state (not stale cache)
        let hasPlayers = !sessionToPlayer.isEmpty
        
        do {
            let state = await keeper.currentState()
            
            // Determine snapshot mode based on dirty tracking
            let broadcastMode: SnapshotMode
            if state.isDirty() {
                let dirtyFields = state.getDirtyFields()
                let syncFields = state.getSyncFields()
                let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
                let broadcastFields = dirtyFields.intersection(broadcastFieldNames)
                
                // Only extract and compare dirty broadcast fields
                broadcastMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
            } else {
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
                if !hasPlayers {
                    logger.debug("📤 Broadcast cache updated (no players connected)", metadata: [
                        "patches": .string("\(broadcastDiff.count)"),
                        "mode": .string("\(broadcastMode)")
                    ])
                }
                return
            }
            
            // Encode once (all players get the same broadcast update)
            let update = StateUpdate.diff(broadcastDiff)
            let updateData = try encoder.encode(update)
            let updateSize = updateData.count
            
            logger.debug("📤 Broadcast-only sync", metadata: [
                "players": .string("\(sessionToPlayer.count)"),
                "patches": .string("\(broadcastDiff.count)"),
                "bytes": .string("\(updateSize)"),
                "mode": .string("\(broadcastMode)")
            ])
            
            // Send to all connected players
            // Handle each send separately to avoid one failure stopping all updates
            for (sessionID, _) in sessionToPlayer {
                do {
                    try await transport.send(updateData, to: .session(sessionID))
                } catch {
                    // Log error but continue sending to other players
                    logger.warning("Failed to send broadcast update to session", metadata: [
                        "sessionID": .string(sessionID.rawValue),
                        "error": .string("\(error)")
                    ])
                }
            }
        } catch {
            logger.error("❌ Failed to sync broadcast-only", metadata: [
                "error": .string("\(error)")
            ])
        }
    }
    
    /// Sync state for a specific player
    private func syncState(
        for playerID: PlayerID,
        sessionID: SessionID,
        state: State,
        broadcastSnapshot: StateSnapshot
    ) async {
        do {
            // Extract per-player snapshot (specific to this player)
            let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
            
            // Use generateDiffFromSnapshots to compute diff/patch with pre-extracted snapshots
            // This reuses the broadcast snapshot and only extracts per-player snapshot per player
            let update = try syncEngine.generateDiffFromSnapshots(
                for: playerID,
                broadcastSnapshot: broadcastSnapshot,
                perPlayerSnapshot: perPlayerSnapshot,
                state: state
            )
            
            // Skip only if noChange - firstSync should always be sent (even if patches are empty)
            // firstSync is a notification that sync has started, not just a data update
            if case .noChange = update {
                return
            }
            
            let updateData = try encoder.encode(update)
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
            
            logger.debug("📤 Sending state update", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "type": .string(updateType),
                "patches": .string("\(patchCount)"),
                "bytes": .string("\(updateSize)")
            ])
            
            // Log update preview (first 500 chars)
            if let updatePreview = String(data: updateData, encoding: .utf8) {
                let preview = updatePreview.count > 500 
                    ? String(updatePreview.prefix(500)) + "..." 
                    : updatePreview
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
    
    /// Sync state for a new player (first connection) using lateJoinSnapshot
    /// This sends the complete initial state as a snapshot (not as patches)
    /// Does NOT mark firstSync as received - that will happen on first actual sync
    private func syncStateForNewPlayer(for playerID: PlayerID, sessionID: SessionID) async {
        do {
            let state = await keeper.currentState()
            
            // Use lateJoinSnapshot to get complete snapshot and populate cache
            // This does NOT mark firstSync as received - that happens on first sync
            // lateJoin only sends complete snapshot, does NOT calculate delta
            let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
            
            // Encode snapshot as JSON and send directly (not as patches)
            let snapshotData = try encoder.encode(snapshot)
            let snapshotSize = snapshotData.count
            
            logger.debug("📤 Sending initial snapshot (late join)", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "bytes": .string("\(snapshotSize)"),
                "fields": .string("\(snapshot.values.count)")
            ])
            
            // Log snapshot preview (first 500 chars)
            if let snapshotPreview = String(data: snapshotData, encoding: .utf8) {
                let preview = snapshotPreview.count > 500 
                    ? String(snapshotPreview.prefix(500)) + "..." 
                    : snapshotPreview
                logger.trace("📤 Snapshot preview", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "preview": .string(preview)
                ])
            }
            
            // Send snapshot directly (not as StateUpdate format)
            // Note: Does NOT mark firstSync as received - that will happen on first sync
            try await transport.send(snapshotData, to: .session(sessionID))
        } catch {
            logger.error("❌ Failed to sync initial state", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
            ])
        }
    }
    
    /// Sync state for a specific player (legacy method for backward compatibility)
    private func syncState(for playerID: PlayerID, sessionID: SessionID) async {
        do {
            let state = await keeper.currentState()
            let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
            await syncState(for: playerID, sessionID: sessionID, state: state, broadcastSnapshot: broadcastSnapshot)
        } catch {
            logger.error("❌ Failed to sync state", metadata: [
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "error": .string("\(error)")
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
        // Phase 1: Validation (no state modification)
        guard let clientID = sessionToClient[sessionID] else {
            logger.warning("Join request from unknown session: \(sessionID.rawValue)")
            await sendJoinResponse(requestID: requestID, sessionID: sessionID, success: false, reason: "Session not connected")
            return
        }
        
        // Check if already joined
        if sessionToPlayer[sessionID] != nil {
            logger.warning("Join request from already joined session: \(sessionID.rawValue)")
            await sendJoinResponse(requestID: requestID, sessionID: sessionID, success: false, reason: "Already joined")
            return
        }
        
        // Verify landID matches
        guard landID == self.landID else {
            logger.warning("Join request with mismatched landID: expected=\(self.landID), received=\(landID)")
            await sendJoinResponse(requestID: requestID, sessionID: sessionID, success: false, reason: "Land ID mismatch")
            return
        }
        
        // Phase 2: Preparation (no state modification)
        // Create PlayerSession with priority: join message > JWT payload > guest session
        let jwtAuthInfo = sessionToAuthInfo[sessionID]
        
        // Determine playerID: join message > JWT payload > guest session
        let finalPlayerID: String
        if let requestedPlayerID = requestedPlayerID {
            finalPlayerID = requestedPlayerID
        } else if let jwtPlayerID = jwtAuthInfo?.playerID {
            finalPlayerID = jwtPlayerID  // Use JWT payload
        } else {
            // No JWT payload available, use guest session
            let guestSession = createGuestSession(sessionID, clientID)
            finalPlayerID = guestSession.playerID
        }
        
        // Determine deviceID: join message > JWT payload > guest session
        let finalDeviceID: String?
        if let joinDeviceID = deviceID {
            finalDeviceID = joinDeviceID
        } else if let jwtDeviceID = jwtAuthInfo?.deviceID {
            finalDeviceID = jwtDeviceID  // Use JWT payload
        } else {
            let guestSession = createGuestSession(sessionID, clientID)
            finalDeviceID = guestSession.deviceID
        }
        
        // Merge metadata: join message metadata > JWT payload metadata > guest session metadata
        // Join message metadata takes precedence, then JWT payload, then guest session
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
        
        // If no metadata from JWT or join message, use guest session metadata
        if finalMetadata.isEmpty {
            let guestSession = createGuestSession(sessionID, clientID)
            finalMetadata = guestSession.metadata
        }
        
        // Create final PlayerSession
        let playerSession = PlayerSession(
            playerID: finalPlayerID,
            deviceID: finalDeviceID,
            metadata: finalMetadata
        )
        
        // Log metadata sources for debugging
        if let jwtAuthInfo = jwtAuthInfo {
            logger.debug("Using JWT payload for join", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "jwtPlayerID": .string(jwtAuthInfo.playerID),
                "jwtMetadataCount": .string("\(jwtAuthInfo.metadata.count)"),
                "finalPlayerID": .string(finalPlayerID),
                "finalMetadataCount": .string("\(finalMetadata.count)")
            ])
        }
        
        // Phase 3: Atomic join operation (with rollback on failure)
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
            // Attempt to join (updates keeper.players)
            let decision = try await keeper.join(
                session: playerSession,
                clientID: clientID,
                sessionID: sessionID
            )
            
            switch decision {
            case .allow(let pid):
                playerID = pid
                
                // Update TransportAdapter state (synchronization point)
                sessionToPlayer[sessionID] = pid
                
                // Send initial snapshot
                // Note: syncStateForNewPlayer handles errors internally and logs them
                // If it fails, we still mark join as succeeded since the player is already in keeper.players
                // The client will receive the join response but may need to retry or handle missing initial state
                await syncStateForNewPlayer(for: pid, sessionID: sessionID)
                syncEngine.markFirstSyncReceived(for: pid)
                joinSucceeded = true
                await sendJoinResponse(requestID: requestID, sessionID: sessionID, success: true, playerID: pid.rawValue)
                
                logger.info("Client joined: session=\(sessionID.rawValue), player=\(pid.rawValue), playerID=\(playerSession.playerID)")
                
            case .deny(let reason):
                // Join denied
                logger.warning("Join denied for session \(sessionID.rawValue): \(reason ?? "no reason provided")")
                await sendJoinResponse(requestID: requestID, sessionID: sessionID, success: false, reason: reason)
            }
        } catch {
            // Join failed (e.g., JoinError.roomIsFull)
            logger.error("Join failed for session \(sessionID.rawValue): \(error)")
            await sendJoinResponse(requestID: requestID, sessionID: sessionID, success: false, reason: "\(error)")
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
    
    /// Send join response to client
    private func sendJoinResponse(
        requestID: String,
        sessionID: SessionID,
        success: Bool,
        playerID: String? = nil,
        reason: String? = nil
    ) async {
        do {
            let response = TransportMessage.joinResponse(
                requestID: requestID,
                success: success,
                playerID: playerID,
                reason: reason
            )
            let responseData = try encoder.encode(response)
            try await transport.send(responseData, to: .session(sessionID))
            
            logger.debug("📤 Sent join response", metadata: [
                "requestID": "\(requestID)",
                "sessionID": "\(sessionID.rawValue)",
                "success": "\(success)",
                "playerID": "\(playerID ?? "nil")"
            ])
        } catch {
            logger.error("❌ Failed to send join response", metadata: [
                "requestID": "\(requestID)",
                "sessionID": "\(sessionID.rawValue)",
                "error": "\(error)"
            ])
        }
    }
}
