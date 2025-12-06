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
    
    /// Closure to create PlayerSession from sessionID and clientID.
    /// This allows customizing how playerID, deviceID, and metadata are extracted.
    /// Default implementation uses sessionID as playerID.
    public var createPlayerSession: @Sendable (SessionID, ClientID) -> PlayerSession = { sessionID, _ in
        PlayerSession(playerID: sessionID.rawValue, deviceID: nil, metadata: [:])
    }
    
    public init(
        keeper: LandKeeper<State>,
        transport: WebSocketTransport,
        landID: String,
        createPlayerSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
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
                label: "com.swiftstatetree.transport",
                scope: "TransportAdapter"
            )
        }
        if let createPlayerSession = createPlayerSession {
            self.createPlayerSession = createPlayerSession
        }
    }
    
    public func onConnect(sessionID: SessionID, clientID: ClientID) async {
        // Create PlayerSession using the configured closure
        let playerSession = createPlayerSession(sessionID, clientID)
        
        // Join using CanJoin handler (if defined) or default join logic
        do {
            let decision = try await keeper.join(
                session: playerSession,
                clientID: clientID,
                sessionID: sessionID
            )
            
            guard case .allow(let playerID) = decision else {
                // Join was denied by CanJoin handler
                if case .deny(let reason) = decision {
                    logger.warning("Join denied for session \(sessionID.rawValue): \(reason ?? "no reason provided")")
                } else {
                    logger.warning("Join denied for session \(sessionID.rawValue): unknown reason")
                }
                return
            }
            
            sessionToPlayer[sessionID] = playerID
            sessionToClient[sessionID] = clientID
            
            // Send initial snapshot using lateJoinSnapshot for complete state
            await syncStateForNewPlayer(for: playerID, sessionID: sessionID)
            
            logger.info("Client connected: session=\(sessionID.rawValue), player=\(playerID.rawValue), playerID=\(playerSession.playerID)")
        } catch {
            // CanJoin handler threw an error (e.g., JoinError.roomIsFull)
            logger.error("Join failed for session \(sessionID.rawValue): \(error)")
            // Don't proceed with connection if join validation fails
        }
    }
    
    public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        guard let playerID = sessionToPlayer[sessionID] else { return }
        
        await keeper.leave(playerID: playerID, clientID: clientID)
        sessionToPlayer.removeValue(forKey: sessionID)
        sessionToClient.removeValue(forKey: sessionID)
        
        logger.info("Client disconnected: session=\(sessionID.rawValue), player=\(playerID.rawValue)")
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
            
            guard let playerID = sessionToPlayer[sessionID],
                  let clientID = sessionToClient[sessionID] else {
                logger.warning("Unknown session: \(sessionID.rawValue)")
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
        // Extract broadcast snapshot once and reuse for all players
        do {
            let state = await keeper.currentState()
            
            // Extract broadcast snapshot once (shared across all players)
            let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
            
            // Sync state for all connected players using shared broadcast snapshot
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
}
