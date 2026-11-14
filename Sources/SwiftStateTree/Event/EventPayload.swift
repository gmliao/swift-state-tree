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

/// A payload's positional form, written by `@Payload`: its fields in name order, for the
/// compressed encodings, where field names are omitted (#521).
public protocol PayloadCompression {
    /// Hands each field, in name order, to `writer`. `@Payload` writes it.
    func _writePayloadFields<W: _PayloadFieldWriter>(into writer: inout W) throws
    /// Whether the type has a positional writer: true for `@Payload` types.
    static var _payloadHasTypedWriter: Bool { get }
    /// The name the schema and the wire use for the type.
    static var _payloadWireName: String { get }
    /// Each field and how the writer writes it, in field order.
    static var _payloadFieldForms: [_PayloadFieldFormEntry] { get }
}

// Provide a default metadata implementation so enums and non-macro types still compile.
extension ClientEventPayload {
    public static func getFieldMetadata() -> [FieldMetadata] { [] }
}

// Provide a default metadata implementation so enums and non-macro types still compile.
extension ServerEventPayload {
    public static func getFieldMetadata() -> [FieldMetadata] { [] }
}

// A type without `@Payload` has no positional writer: writing it throws, and registration
// refuses such a type where payloads are compressed (EV1, #521).
extension PayloadCompression {
    public func _writePayloadFields<W: _PayloadFieldWriter>(into writer: inout W) throws {
        throw PayloadWithoutWriterError(typeName: String(describing: Self.self))
    }

    public static var _payloadHasTypedWriter: Bool { false }

    /// The event rule, for a type whose name `@Payload` couldn't fix at expansion.
    public static var _payloadWireName: String { payloadEventName(for: Self.self) }

    public static var _payloadFieldForms: [_PayloadFieldFormEntry] { [] }
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
    /// The event type name is the type's `_payloadWireName`, the schema's name
    /// (e.g., "MoveToEvent" -> "MoveTo").
    public init<E: ClientEventPayload>(_ event: E) {
        self.type = E._payloadWireName
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

    /// The event as its typed value, for the positional encoders (#521): set by `init(_:)` for a
    /// type with a positional writer; nil for the hand-built form, `init(type:payload:rawBody:)`.
    package private(set) var wireForm: (any ServerEventPayload)? = nil

    private enum CodingKeys: String, CodingKey {
        case type, payload, rawBody
    }
    
    public init(type: String, payload: AnyCodable, rawBody: Data? = nil) {
        self.type = type
        self.payload = payload
        self.rawBody = rawBody
    }
    
    /// Create an AnyServerEvent from a concrete ServerEventPayload.
    ///
    /// The event type name is the type's `_payloadWireName`, the schema's name
    /// (e.g., "PlayerShootEvent" -> "PlayerShoot").
    public init<E: ServerEventPayload>(_ event: E) {
        self.type = E._payloadWireName
        self.payload = AnyCodable(event)
        self.rawBody = nil
        self.wireForm = E._payloadHasTypedWriter ? event : nil
    }
    
}
