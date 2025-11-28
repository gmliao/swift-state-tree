import Foundation
import SwiftStateTree

/// Adapts Transport events to LandKeeper calls.
public actor TransportAdapter<State, ClientE, ServerE>: TransportDelegate
where State: StateNodeProtocol,
      ClientE: ClientEventPayload,
      ServerE: ServerEventPayload {
    
    private let keeper: LandKeeper<State, ClientE, ServerE>
    private let transport: WebSocketTransport
    private let landID: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let syncEngine = SyncEngine()
    
    // Track session to player mapping
    private var sessionToPlayer: [SessionID: PlayerID] = [:]
    private var sessionToClient: [SessionID: ClientID] = [:]
    
    public init(keeper: LandKeeper<State, ClientE, ServerE>, transport: WebSocketTransport, landID: String) {
        self.keeper = keeper
        self.transport = transport
        self.landID = landID
    }
    
    public func onConnect(sessionID: SessionID, clientID: ClientID) async {
        // Generate playerID from session (in real app, this would come from auth)
        let playerID = PlayerID("player-\(sessionID.rawValue)")
        sessionToPlayer[sessionID] = playerID
        sessionToClient[sessionID] = clientID
        
        // Join the player to the land
        await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
        
        // Send initial snapshot
        await syncState(for: playerID, sessionID: sessionID)
        
        print("Client connected: \(sessionID) -> \(playerID)")
    }
    
    public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        guard let playerID = sessionToPlayer[sessionID] else { return }
        
        await keeper.leave(playerID: playerID, clientID: clientID)
        sessionToPlayer.removeValue(forKey: sessionID)
        sessionToClient.removeValue(forKey: sessionID)
        
        print("Client disconnected: \(sessionID) -> \(playerID)")
    }
    
    public func onMessage(_ message: Data, from sessionID: SessionID) async {
        do {
            let transportMsg = try decoder.decode(TransportMessage<ClientE, ServerE>.self, from: message)
            
            guard let playerID = sessionToPlayer[sessionID],
                  let clientID = sessionToClient[sessionID] else {
                print("Unknown session: \(sessionID)")
                return
            }
            
            switch transportMsg {
            case .action(let requestID, let landID, let envelope):
                // TODO: Decode action based on typeIdentifier
                // For now, just log it
                print("Received action: \(envelope.typeIdentifier) from \(playerID)")
                _ = requestID
                _ = landID
                
            case .event(let landID, let eventWrapper):
                _ = landID
                if case .fromClient(let clientEvent) = eventWrapper {
                    await keeper.handleClientEvent(clientEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
                }
                
            case .actionResponse:
                // Server usually doesn't receive action responses from clients
                break
            }
        } catch {
            print("Failed to decode message: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    /// Send server event to specified target
    public func sendEvent(_ event: any ServerEventPayload, to target: SwiftStateTree.EventTarget) async {
        do {
            // Cast to ServerE type
            guard let serverEvent = event as? ServerE else {
                print("Event type mismatch")
                return
            }
            
            let transportMsg = TransportMessage<ClientE, ServerE>.event(
                landID: landID,
                event: .fromServer(serverEvent)
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
                    print("No session found for client: \(clientID)")
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
            print("Failed to send event: \(error)")
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
            print("Failed to sync state: \(error)")
        }
    }
}
