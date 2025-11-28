import Foundation
import SwiftStateTree

// MARK: - Transport Protocol

/// Protocol defining the interface for a network transport layer.
///
/// A Transport is responsible for:
/// 1. Managing connections (clients).
/// 2. Receiving messages from clients and forwarding them to the delegate (LandKeeper).
/// 3. Sending messages from the delegate to clients.
public protocol Transport: Actor {
    /// The delegate that handles incoming messages (typically an adapter for LandKeeper).
    var delegate: TransportDelegate? { get set }
    
    /// Starts the transport (e.g., starts listening on a port).
    func start() async throws
    
    /// Stops the transport.
    func stop() async throws
    
    /// Sends a message to a specific target.
    ///
    /// - Parameters:
    ///   - message: The message payload (already encoded as Data or TransportMessage).
    ///   - target: The recipients of the message.
    func send(_ message: Data, to target: EventTarget) async throws
}

// MARK: - Transport Delegate

/// Delegate protocol for handling events from the Transport layer.
public protocol TransportDelegate: Sendable {
    /// Called when a client connects.
    func onConnect(sessionID: SessionID, clientID: ClientID) async
    
    /// Called when a client disconnects.
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async
    
    /// Called when a message is received from a client.
    func onMessage(_ message: Data, from sessionID: SessionID) async
}

// MARK: - Event Target

/// Specifies the recipients of a message.
public enum EventTarget: Sendable {
    /// Send to a specific session/connection.
    case session(SessionID)
    
    /// Send to a specific player (could be multiple sessions).
    case player(PlayerID)
    
    /// Broadcast to all connected clients.
    case broadcast
    
    /// Broadcast to all except a specific session (e.g., "everyone else").
    case broadcastExcept(SessionID)
}
