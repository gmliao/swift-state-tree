import Foundation
import SwiftStateTree

/// Pipeline component for routing decoded messages to appropriate handlers.
///
/// This component simplifies the large switch statement in `onMessage`, making it easier
/// to add new message types and maintain routing logic.
///
/// **Performance**: This is a value type (struct) with zero allocation overhead. All logic remains
/// within TransportAdapter's actor isolation domain (no actor hopping).
struct MessageRoutingTable: Sendable {
    
    /// Route a decoded message to the appropriate handler.
    ///
    /// This method centralizes all message routing logic, replacing the large switch statement
    /// in TransportAdapter.onMessage.
    ///
    /// - Parameters:
    ///   - message: Decoded transport message
    ///   - sessionID: Session ID of the sender
    ///   - adapter: TransportAdapter instance to handle the message
    func route<State: StateNodeProtocol>(
        _ message: TransportMessage,
        from sessionID: SessionID,
        to adapter: TransportAdapter<State>
    ) async {
        switch message.kind {
        case .join:
            await adapter.handleJoinMessage(message, from: sessionID)
            
        case .joinResponse:
            await adapter.handleJoinResponse(from: sessionID)
            
        case .error:
            await adapter.handleErrorFromClient(from: sessionID)
            
        case .action, .actionResponse, .event:
            // These messages require player to be joined
            await adapter.handlePlayerMessage(message, from: sessionID)
        }
    }
}
