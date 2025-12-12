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
    /// Default implementation uses the sessionID as playerID for deterministic guest identities.
    public var createGuestSession: @Sendable (SessionID, ClientID) -> PlayerSession = { sessionID, clientID in
        return PlayerSession(
            playerID: sessionID.rawValue,
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
            do {
                try await keeper.leave(playerID: playerID, clientID: clientID)
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
        
        logger.info("Client disconnected: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
        } else {
            logger.info("Client disconnected (was not joined): session=\(sessionID.rawValue)")
        }
    }
    
    public func onMessage(_ message: Data, from sessionID: SessionID) async {
        let messageSize = message.count
        
        logger.debug("📥 Received message", metadata: [
            "session": .string(sessionID.rawValue),
            "bytes": .string("\(messageSize)")
        ])
        
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
            let transportMsg = try decoder.decode(TransportMessage.self, from: message)
            
            switch transportMsg.kind {
            case .join:
                if case .join(let payload) = transportMsg.payload {
                    // Handle join request (can be sent before player is joined)
                    await handleJoinRequest(
                        requestID: payload.requestID,
                        landID: payload.landID,
                        sessionID: sessionID,
                        requestedPlayerID: payload.playerID,
                        deviceID: payload.deviceID,
                        metadata: payload.metadata
                    )
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
                            "landID": .string(payload.landID),
                            "actionType": .string(payload.action.typeIdentifier),
                            "playerID": .string(playerID.rawValue),
                            "sessionID": .string(sessionID.rawValue)
                        ])
                        
                        // Decode action payload if possible - only compute if trace logging is enabled
                        if let payloadString = logger.safePreview(from: payload.action.payload) {
                            logger.trace("📥 Action payload", metadata: [
                                "requestID": .string(payload.requestID),
                                "payload": .string(payloadString)
                            ])
                        }
                        
                        // Handle action request
                        await handleActionRequest(
                            requestID: payload.requestID,
                            landID: payload.landID,
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
                        if let responseData = try? encoder.encode(payload.response),
                           let responseString = logger.safePreview(from: responseData) {
                            logger.trace("📥 Response payload", metadata: [
                                "requestID": .string(payload.requestID),
                                "response": .string(responseString)
                            ])
                        }
                    }
                    
                case .event:
                    if case .event(let payload) = transportMsg.payload {
                        if case .fromClient(let anyClientEvent) = payload.event {
                            logger.info("📥 Received client event", metadata: [
                                "landID": .string(payload.landID),
                                "eventType": .string(anyClientEvent.type),
                                "playerID": .string(playerID.rawValue),
                                "sessionID": .string(sessionID.rawValue)
                            ])
                            
                            // Log event payload - only compute if trace logging is enabled
                            if let payloadData = try? encoder.encode(anyClientEvent.payload),
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
                                if let errorData = try? encoder.encode(errorResponse) {
                                    try? await transport.send(errorData, to: .session(sessionID))
                                }
                            }
                        } else if case .fromServer = payload.event {
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
                let errorData = try encoder.encode(errorResponse)
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
                landID: landID,
                event: .fromServer(event: event)
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
            
            // Log event payload - only compute if trace logging is enabled
            if let payloadData = try? encoder.encode(event.payload),
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
            logger.debug("⏭️ Sync skipped: another sync operation is in progress")
            return
        }
        
        // Extract broadcast snapshot once and reuse for all players
        do {
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
            
            // Release sync lock after successful sync
            await keeper.endSync()
        } catch {
            logger.error("❌ Failed to extract broadcast snapshot", metadata: [
                "error": .string("\(error)")
            ])
            // TODO: Consider re-syncing after error recovery
            // TODO: Add error metrics to track sync failure rates
            
            // Always release sync lock, even if error occurred
            await keeper.endSync()
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
            logger.debug("⏭️ Broadcast-only sync skipped: another sync operation is in progress")
            return
        }
        
        do {
            
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
            
            // Release sync lock after successful sync
            await keeper.endSync()
        } catch {
            logger.error("❌ Failed to sync broadcast-only", metadata: [
                "error": .string("\(error)")
            ])
            
            // Always release sync lock, even if error occurred
            await keeper.endSync()
        }
    }
    
    /// Sync state for a specific player
    ///
    /// This method extracts per-player snapshot and computes diff for a single player.
    /// It reuses the broadcast snapshot to avoid redundant extraction.
    ///
    /// TODO: Optimization opportunities:
    /// - Batch per-player snapshot extraction for multiple players
    /// - Parallelize per-player diff computation (requires careful cache management)
    /// - Cache per-player snapshots if state hasn't changed
    /// - Consider incremental sync for large state trees
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
            
            // Log snapshot preview (first 500 chars) - only compute if trace logging is enabled
            if let preview = logger.safePreview(from: snapshotData, maxLength: 500) {
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
    
    /// Handle action request from client
    private func handleActionRequest(
        requestID: String,
        landID: String,
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
            let responseData = try encoder.encode(actionResponse)
            let responseSize = responseData.count
            
            logger.info("📤 Sending action response", metadata: [
                "requestID": .string(requestID),
                "actionType": .string(typeIdentifier),
                "playerID": .string(playerID.rawValue),
                "sessionID": .string(sessionID.rawValue),
                "bytes": .string("\(responseSize)")
            ])
            
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
                let errorData = try encoder.encode(errorResponse)
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
        
        // Phase 2: Preparation (no state modification)
        // Create PlayerSession with priority: join message > JWT payload > guest session
        let jwtAuthInfo = sessionToAuthInfo[sessionID]
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
        
        // If no metadata from JWT or join message, use guest session metadata when available
        if finalMetadata.isEmpty, metadata == nil, let guestMetadata = guestSession?.metadata {
            finalMetadata = guestMetadata
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
                sessionID: sessionID,
                services: LandServices()
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
                await sendJoinError(requestID: requestID, sessionID: sessionID, code: .joinDenied, message: reason ?? "Join denied")
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
            let errorData = try encoder.encode(errorResponse)
            try await transport.send(errorData, to: .session(sessionID))
            
            logger.debug("📤 Sent join error", metadata: [
                "requestID": "\(requestID)",
                "sessionID": "\(sessionID.rawValue)",
                "code": "\(code.rawValue)"
            ])
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
