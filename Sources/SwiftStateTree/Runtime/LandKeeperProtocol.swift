import Foundation

/// Protocol abstraction for LandKeeper operations.
///
/// This protocol allows LandKeeper to be abstracted for future distributed actor support.
/// All method parameters and return values must be Sendable and Codable to support
/// serialization across process boundaries.
public protocol LandKeeperProtocol: Actor {
    associatedtype State: StateNodeProtocol
    
    /// Returns the current state snapshot.
    ///
    /// This is a read-only view of the state. Mutations should be done through action/event handlers.
    func currentState() -> State
    
    /// Handles a player joining the Land with session-based validation.
    ///
    /// - Parameters:
    ///   - session: The player session information.
    ///   - clientID: The client instance identifier.
    ///   - sessionID: The session/connection identifier.
    ///   - services: Services to inject into the LandContext.
    /// - Returns: JoinDecision indicating if the join was allowed or denied.
    /// - Throws: Errors from the CanJoin handler if join validation fails.
    func join(
        session: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices
    ) async throws -> JoinDecision
    
    /// Handles a player/client leaving the Land.
    ///
    /// - Parameters:
    ///   - playerID: The player's unique identifier.
    ///   - clientID: The client instance identifier.
    /// - Throws: Errors from the OnLeave handler (e.g., resolver failures)
    func leave(playerID: PlayerID, clientID: ClientID) async throws
    
    /// Handles an action from a player.
    ///
    /// - Parameters:
    ///   - action: The action payload (type-erased as AnyCodable).
    ///   - playerID: The player sending the action.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// - Returns: The action result (type-erased as AnyCodable).
    /// - Throws: `LandError.actionNotRegistered` if no handler is found.
    func handleActionEnvelope(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> AnyCodable
    
    /// Handles a client event from a player.
    ///
    /// - Parameters:
    ///   - event: The client event (type-erased).
    ///   - playerID: The player sending the event.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// - Throws: Errors from event handler execution (e.g., resolver failures)
    func handleClientEvent(
        _ event: AnyClientEvent,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws
}

