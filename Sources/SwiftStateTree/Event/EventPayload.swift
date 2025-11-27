import Foundation

// MARK: - Event Payload Protocols

/// Protocol for client events (Client -> Server)
///
/// Users should define concrete enum or struct types conforming to this protocol.
public protocol ClientEventPayload: Codable, Sendable {}

/// Protocol for server events (Server -> Client)
///
/// Users should define concrete enum or struct types conforming to this protocol.
public protocol ServerEventPayload: Codable, Sendable {}

// MARK: - Generic Event Container

/// Generic event container for type-safe event handling
///
/// Wraps client and server events in a single enum.
public enum Event<C: ClientEventPayload, S: ServerEventPayload>: Codable, Sendable {
    case fromClient(C)
    case fromServer(S)
}
