import Foundation

// MARK: - Event Payload Protocols

/// Protocol for client events (Client -> Server)
///
/// Users should define concrete enum or struct types conforming to this protocol.
public protocol ClientEventPayload: Codable, Sendable, SchemaMetadataProvider {}

/// Protocol for server events (Server -> Client)
///
/// Users should define concrete enum or struct types conforming to this protocol.
public protocol ServerEventPayload: Codable, Sendable, SchemaMetadataProvider {}

// Provide a default metadata implementation so enums and non-macro types still compile.
extension ClientEventPayload {
    public static func getFieldMetadata() -> [FieldMetadata] { [] }
}

// Provide a default metadata implementation so enums and non-macro types still compile.
extension ServerEventPayload {
    public static func getFieldMetadata() -> [FieldMetadata] { [] }
}

// MARK: - Generic Event Container

/// Generic event container for type-safe event handling
///
/// Wraps client and server events in a single enum.
public enum Event<C: ClientEventPayload, S: ServerEventPayload>: Codable, Sendable {
    case fromClient(C)
    case fromServer(S)
}

// MARK: - Root Event Types

/// Type-erased root type for all client events.
///
/// This is the fixed root type used throughout the system for client events.
/// It contains the event type name and the payload as `AnyCodable`.
public struct AnyClientEvent: Codable, Sendable {
    /// The event type identifier (e.g., "WelcomeEvent", "ChatMessageEvent").
    public let type: String
    
    /// The event payload as a type-erased codable value.
    public let payload: AnyCodable
    
    /// Optional raw body for future extensibility.
    public let rawBody: Data?
    
    public init(type: String, payload: AnyCodable, rawBody: Data? = nil) {
        self.type = type
        self.payload = payload
        self.rawBody = rawBody
    }
    
    /// Create an AnyClientEvent from a concrete ClientEventPayload.
    ///
    /// The event type name is derived from the type name using `String(describing: type(of: event))`.
    public init<E: ClientEventPayload>(_ event: E) {
        self.type = String(describing: Swift.type(of: event))
        self.payload = AnyCodable(event)
        self.rawBody = nil
    }
}

/// Type-erased root type for all server events.
///
/// This is the fixed root type used throughout the system for server events.
/// It contains the event type name and the payload as `AnyCodable`.
public struct AnyServerEvent: Codable, Sendable {
    /// The event type identifier (e.g., "WelcomeEvent", "ChatMessageEvent").
    public let type: String
    
    /// The event payload as a type-erased codable value.
    public let payload: AnyCodable
    
    /// Optional raw body for future extensibility.
    public let rawBody: Data?
    
    public init(type: String, payload: AnyCodable, rawBody: Data? = nil) {
        self.type = type
        self.payload = payload
        self.rawBody = rawBody
    }
    
    /// Create an AnyServerEvent from a concrete ServerEventPayload.
    ///
    /// The event type name is derived from the type name using `String(describing: type(of: event))`.
    public init<E: ServerEventPayload>(_ event: E) {
        self.type = String(describing: Swift.type(of: event))
        self.payload = AnyCodable(event)
        self.rawBody = nil
    }
}
