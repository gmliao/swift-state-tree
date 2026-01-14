import Foundation

// MARK: - Event Payload Protocols

/// Protocol for client events (Client -> Server)
///
/// Users should define concrete enum or struct types conforming to this protocol.
public protocol ClientEventPayload: Codable, Sendable, SchemaMetadataProvider, PayloadCompression {}

/// Protocol for server events (Server -> Client)
///
/// Users should define concrete enum or struct types conforming to this protocol.
public protocol ServerEventPayload: Codable, Sendable, SchemaMetadataProvider, PayloadCompression {}

// MARK: - Payload Compression Protocol

/// Protocol for payloads that can be encoded as arrays for compression
public protocol PayloadCompression {
    /// Encode the payload as an array of values in field order
    /// This is used for opcode-based compression where field names are omitted
    func encodeAsArray() -> [AnyCodable]
}

// Provide a default metadata implementation so enums and non-macro types still compile.
extension ClientEventPayload {
    public static func getFieldMetadata() -> [FieldMetadata] { [] }
}

// Provide a default metadata implementation so enums and non-macro types still compile.
extension ServerEventPayload {
    public static func getFieldMetadata() -> [FieldMetadata] { [] }
}

// No default implementation - @Payload macro is required
// This ensures correct field order for opcode-based compression
// If you see this error, add @Payload macro to your event/action struct
extension PayloadCompression {
    public func encodeAsArray() -> [AnyCodable] {
        fatalError("encodeAsArray() must be implemented by @Payload macro. Type '\(type(of: self))' is missing @Payload macro.")
    }
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
    /// The event type name is derived from the type name, removing the "Event" suffix
    /// to match schema generation (e.g., "MoveToEvent" -> "MoveTo").
    public init<E: ClientEventPayload>(_ event: E) {
        self.type = Self.eventName(for: Swift.type(of: event))
        self.payload = AnyCodable(event)
        self.rawBody = nil
    }
    
    /// Generate event name from event type, matching schema generation logic.
    ///
    /// Removes the "Event" suffix if present to ensure consistency with schema eventHashes.
    /// Example: "MoveToEvent" -> "MoveTo", "ChatMessageEvent" -> "ChatMessage"
    private static func eventName(for eventType: Any.Type) -> String {
        let typeName = String(describing: eventType)
        
        // Extract base type name (handle module prefixes)
        var baseTypeName: String
        if let lastComponent = typeName.split(separator: ".").last {
            baseTypeName = String(lastComponent)
        } else {
            baseTypeName = typeName
        }
        
        // Remove "Event" suffix if present, keep camelCase format
        // Example: "ChatEvent" -> "Chat", "PingEvent" -> "Ping"
        var eventID = baseTypeName
        if eventID.hasSuffix("Event") {
            eventID = String(eventID.dropLast(5))
        }
        
        return eventID
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
    /// The event type name is derived from the type name, removing the "Event" suffix
    /// to match schema generation (e.g., "PlayerShootEvent" -> "PlayerShoot").
    public init<E: ServerEventPayload>(_ event: E) {
        self.type = Self.eventName(for: Swift.type(of: event))
        self.payload = AnyCodable(event)
        self.rawBody = nil
    }
    
    /// Generate event name from event type, matching schema generation logic.
    ///
    /// Removes the "Event" suffix if present to ensure consistency with schema eventHashes.
    /// Example: "PlayerShootEvent" -> "PlayerShoot", "ChatMessageEvent" -> "ChatMessage"
    private static func eventName(for eventType: Any.Type) -> String {
        let typeName = String(describing: eventType)
        
        // Extract base type name (handle module prefixes)
        var baseTypeName: String
        if let lastComponent = typeName.split(separator: ".").last {
            baseTypeName = String(lastComponent)
        } else {
            baseTypeName = typeName
        }
        
        // Remove "Event" suffix if present, keep camelCase format
        // Example: "ChatEvent" -> "Chat", "PingEvent" -> "Ping"
        var eventID = baseTypeName
        if eventID.hasSuffix("Event") {
            eventID = String(eventID.dropLast(5))
        }
        
        return eventID
    }
}
