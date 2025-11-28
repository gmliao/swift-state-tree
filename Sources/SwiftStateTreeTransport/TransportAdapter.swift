import Foundation
import SwiftStateTree

/// Adapts Transport events to LandKeeper calls.
public actor TransportAdapter<State, ClientE, ServerE>: TransportDelegate
where State: StateNodeProtocol,
      ClientE: ClientEventPayload,
      ServerE: ServerEventPayload {
    
    private let keeper: LandKeeper<State, ClientE, ServerE>
    private let decoder = JSONDecoder()
    
    public init(keeper: LandKeeper<State, ClientE, ServerE>) {
        self.keeper = keeper
    }
    
    public func onConnect(sessionID: SessionID, clientID: ClientID) async {
        // In a real app, we might wait for a "Join" action instead of auto-joining on connect.
        // But for simplicity, we can log it or prepare resources.
        print("Client connected: \(sessionID)")
    }
    
    public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        // We might need a mapping from SessionID to PlayerID if we want to call leave(playerID).
        // For now, we assume the Transport or LandKeeper handles session tracking.
        // Since LandKeeper.leave requires PlayerID, we might need to store that mapping here or in Transport.
    }
    
    public func onMessage(_ message: Data, from sessionID: SessionID) async {
        do {
            let transportMsg = try decoder.decode(TransportMessage<ClientE, ServerE>.self, from: message)
            
            switch transportMsg {
            case .action(let requestID, let landID, let envelope):
                // TODO: Need to extract PlayerID/ClientID from session or envelope
                // For now, using placeholders as this requires Authentication integration
                let playerID = PlayerID("guest-\(sessionID.rawValue)")
                let clientID = ClientID("client-\(sessionID.rawValue)")
                
                // We need to decode the specific action payload.
                // Since ActionEnvelope only has Data, we need to know the type.
                // LandKeeper.handleAction requires a concrete ActionPayload type.
                // This part is tricky with generics. We might need a way to look up the Action type by identifier.
                print("Received action: \(envelope.typeIdentifier)")
                
            case .event(let landID, let eventWrapper):
                if case .fromClient(let clientEvent) = eventWrapper {
                    let playerID = PlayerID("guest-\(sessionID.rawValue)")
                    let clientID = ClientID("client-\(sessionID.rawValue)")
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
}
