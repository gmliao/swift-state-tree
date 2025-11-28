import Foundation

// MARK: - Protocol Schema

/// The top-level structure representing the generated protocol schema.
/// 
/// This matches the format defined in DESIGN_PROTOCOL_SCHEMA.md:
/// ```jsonc
/// {
///   "version": "0.1.0",
///   "lands": {
///     "MatchLand": {
///       "stateType": "MatchLandState",
///       "actions": { ... },
///       "events": { ... },
///       "sync": { ... }
///     }
///   },
///   "defs": { ... }
/// }
/// ```
public struct ProtocolSchema: Codable, Sendable {
    public let version: String
    public let lands: [String: LandSchema]
    public let defs: [String: JSONSchema]
    
    public init(version: String = "0.1.0", lands: [String: LandSchema] = [:], defs: [String: JSONSchema] = [:]) {
        self.version = version
        self.lands = lands
        self.defs = defs
    }
}

/// Schema for a single Land definition.
public struct LandSchema: Codable, Sendable {
    /// The root state tree type name (e.g., "MatchLandState").
    public let stateType: String
    
    /// Action ID → Payload Schema reference.
    /// Action IDs should follow the pattern: `<domain>.<action>` (e.g., "match.join").
    public let actions: [String: JSONSchema]
    
    /// Server Event ID → Payload Schema reference.
    public let events: [String: JSONSchema]
    
    /// Sync-related payload types.
    public let sync: SyncSchema
    
    public init(
        stateType: String,
        actions: [String: JSONSchema] = [:],
        events: [String: JSONSchema] = [:],
        sync: SyncSchema
    ) {
        self.stateType = stateType
        self.actions = actions
        self.events = events
        self.sync = sync
    }
}

/// Sync-related schema definitions.
public struct SyncSchema: Codable, Sendable {
    /// Schema reference for the full state snapshot.
    public let snapshot: JSONSchema
    
    /// Schema reference for the diff/patch format.
    public let diff: JSONSchema
    
    public init(snapshot: JSONSchema, diff: JSONSchema) {
        self.snapshot = snapshot
        self.diff = diff
    }
}

// MARK: - JSON Schema

/// Representation of a JSON Schema object.
public struct JSONSchema: Codable, Sendable {
    public var type: SchemaType?
    public var properties: [String: JSONSchema]?
    public var items: Box<JSONSchema>?
    public var required: [String]?
    public var enumValues: [String]?
    public var ref: String?
    public var description: String?
    public var additionalProperties: Box<JSONSchema>?
    public var defaultValue: SnapshotValue?
    
    // Custom extensions
    public var xStateTree: StateTreeMetadata?
    
    public init(
        type: SchemaType? = nil,
        properties: [String: JSONSchema]? = nil,
        items: JSONSchema? = nil,
        required: [String]? = nil,
        enumValues: [String]? = nil,
        ref: String? = nil,
        description: String? = nil,
        additionalProperties: JSONSchema? = nil,
        defaultValue: SnapshotValue? = nil,
        xStateTree: StateTreeMetadata? = nil
    ) {
        self.type = type
        self.properties = properties
        self.items = items.map { Box($0) }
        self.required = required
        self.enumValues = enumValues
        self.ref = ref
        self.description = description
        self.additionalProperties = additionalProperties.map { Box($0) }
        self.defaultValue = defaultValue
        self.xStateTree = xStateTree
    }
    
    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case items
        case required
        case enumValues = "enum"
        case ref = "$ref"
        case description
        case additionalProperties
        case defaultValue = "default"
        case xStateTree = "x-stateTree"
    }
}

public enum SchemaType: String, Codable, Sendable {
    case object
    case array
    case string
    case integer
    case number
    case boolean
    case null
}

// MARK: - State Tree Metadata

public struct StateTreeMetadata: Codable, Sendable {
    public let nodeKind: NodeKind
    public let sync: SyncMetadata?
    
    public init(nodeKind: NodeKind, sync: SyncMetadata? = nil) {
        self.nodeKind = nodeKind
        self.sync = sync
    }
}

public enum NodeKind: String, Codable, Sendable {
    case object
    case array
    case map
    case leaf
}

public struct SyncMetadata: Codable, Sendable {
    public let policy: String
    
    public init(policy: String) {
        self.policy = policy
    }
}

// MARK: - Helpers

/// A box to allow recursive value types.
public final class Box<T: Codable & Sendable>: Codable, Sendable {
    public let value: T
    
    public init(_ value: T) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(T.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
