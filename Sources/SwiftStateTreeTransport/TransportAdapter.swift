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
    private let syncEngine = SyncEngine()
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
            
            // Send initial snapshot
            await syncState(for: playerID, sessionID: sessionID)
            
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
        do {
            let transportMsg = try decoder.decode(TransportMessage.self, from: message)
            
            guard let playerID = sessionToPlayer[sessionID],
                  let clientID = sessionToClient[sessionID] else {
                logger.warning("Unknown session: \(sessionID.rawValue)")
                return
            }
            
            switch transportMsg {
            case .action(let requestID, let landID, let envelope):
                // TODO: Decode action based on typeIdentifier
                // For now, just log it
                logger.debug("Received action: type=\(envelope.typeIdentifier), player=\(playerID.rawValue)")
                _ = requestID
                _ = landID
                
            case .event(let landID, let eventWrapper):
                _ = landID
                if case .fromClient(let anyClientEvent) = eventWrapper {
                    await keeper.handleClientEvent(
                        anyClientEvent,
                        playerID: playerID,
                        clientID: clientID,
                        sessionID: sessionID
                    )
                }
                
            case .actionResponse:
                // Server usually doesn't receive action responses from clients
                break
            }
        } catch {
            logger.error("Failed to decode message: \(error)")
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
            
            // Convert SwiftStateTree.EventTarget to SwiftStateTreeTransport.EventTarget
            let transportTarget: EventTarget
            switch target {
            case .all:
                transportTarget = .broadcast
            case .player(let playerID):
                transportTarget = .player(playerID)
            case .client(let clientID):
                // Find session for this client
                if let sessionID = sessionToClient.first(where: { $0.value == clientID })?.key {
                    transportTarget = .session(sessionID)
                } else {
                    logger.warning("No session found for client: \(clientID.rawValue)")
                    return
                }
            case .session(let sessionID):
                transportTarget = .session(sessionID)
            case .players(let playerIDs):
                // For multiple players, send to each individually
                for playerID in playerIDs {
                    let sessionIDs = sessionToPlayer.filter({ $0.value == playerID }).map({ $0.key })
                    for sessionID in sessionIDs {
                        try await transport.send(data, to: .session(sessionID))
                    }
                }
                return
            }
            
            try await transport.send(data, to: transportTarget)
        } catch {
            logger.error("Failed to send event: \(error)")
        }
    }
    
    /// Trigger immediate state synchronization
    public func syncNow() async {
        // Sync state for all connected players
        for (sessionID, playerID) in sessionToPlayer {
            await syncState(for: playerID, sessionID: sessionID)
        }
    }
    
    /// Sync state for a specific player
    private func syncState(for playerID: PlayerID, sessionID: SessionID) async {
        do {
            let state = await keeper.currentState()
            let snapshot = try syncEngine.snapshot(for: playerID, from: state)
            
            // Encode snapshot as JSON and send
            // TODO: Use proper StateUpdate format with patches
            let snapshotData = try encoder.encode(snapshot)
            
            // For now, send as raw JSON (in production, use StateUpdate format)
            try await transport.send(snapshotData, to: .session(sessionID))
        } catch {
            logger.error("Failed to sync state: player=\(playerID.rawValue), session=\(sessionID.rawValue), error=\(error)")
        }
    }
}
