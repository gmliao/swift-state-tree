import Foundation

// MARK: - Protocol Schema

/// The top-level structure representing the generated protocol schema.
/// 
/// This matches the format defined in DESIGN_PROTOCOL_SCHEMA.md:
/// ```jsonc
/// {
///   "version": "0.1.0",
///   "schemaHash": "a1b2c3d4",
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
    /// Deterministic hash of schema content for version verification.
    /// Clients should send this during join to verify schema compatibility.
    public let schemaHash: String
    public let lands: [String: LandSchema]
    public let defs: [String: JSONSchema]
    /// The wire form a client of this schema must decode (`"x-stateTree"` at the root). Part of
    /// the hash, so a client built for another wire form is refused at join when the server
    /// checks `expectedSchemaHash`. `nil` in a schema read from an older file.
    public let xStateTree: ProtocolSchemaWireForm?

    enum CodingKeys: String, CodingKey {
        case version, schemaHash, lands, defs
        case xStateTree = "x-stateTree"
    }
    
    public init(
        version: String = "0.1.0",
        schemaHash: String = "",
        lands: [String: LandSchema] = [:],
        defs: [String: JSONSchema] = [:],
        xStateTree: ProtocolSchemaWireForm? = .current
    ) {
        self.version = version
        self.schemaHash = schemaHash
        self.lands = lands
        self.defs = defs
        self.xStateTree = xStateTree
    }
    
    /// Creates a copy of this schema with the computed hash filled in.
    public func withComputedHash() -> ProtocolSchema {
        ProtocolSchema(
            version: version,
            schemaHash: computeHash(),
            lands: lands,
            defs: defs,
            xStateTree: xStateTree
        )
    }
    
    /// Compute deterministic hash of schema content (excluding schemaHash field itself).
    ///
    /// Uses a stable JSON encoding (sorted keys) to ensure consistent hash across platforms.
    /// Returns 16-character hex string (64-bit FNV-1a hash).
    public func computeHash() -> String {
        // Create a hashable version without the schemaHash field
        struct HashableSchema: Encodable {
            let version: String
            let lands: [String: LandSchema]
            let defs: [String: JSONSchema]
            let xStateTree: ProtocolSchemaWireForm?

            enum CodingKeys: String, CodingKey {
                case version, lands, defs
                case xStateTree = "x-stateTree"
            }
        }
        
        let hashable = HashableSchema(version: version, lands: lands, defs: defs, xStateTree: xStateTree)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        
        guard let data = try? encoder.encode(hashable) else {
            return "error"
        }
        
        return DeterministicHash.toHex64(DeterministicHash.fnv1a64(data))
    }
}

/// The wire form a schema's clients must decode, declared at the schema root.
public struct ProtocolSchemaWireForm: Codable, Sendable, Equatable {
    /// How the opcode state updates may send an atomic value: `"positional"` means as the array
    /// of its leaves in `leafOrder` (a server on `AtomicValueEncoding.keyed` still sends keyed
    /// values, which a positional decoder accepts too). A client that doesn't know the value
    /// refuses the schema.
    public let atomicEncoding: String

    public init(atomicEncoding: String) {
        self.atomicEncoding = atomicEncoding
    }

    /// What this build sends and decodes.
    public static let current = ProtocolSchemaWireForm(atomicEncoding: "positional")
}

/// Schema for a single Land definition.
public struct LandSchema: Codable, Sendable {
    /// The root state tree type name (e.g., "MatchLandState").
    public let stateType: String
    
    /// Action ID → Payload Schema reference.
    /// Action IDs should follow the pattern: `<domain>.<action>` (e.g., "match.join").
    public let actions: [String: JSONSchema]
    
    /// Client Event ID → Payload Schema reference (Client → Server).
    public let clientEvents: [String: JSONSchema]
    
    /// Server Event ID → Payload Schema reference (Server → Client).
    public let events: [String: JSONSchema]
    
    /// Sync-related payload types.
    public let sync: SyncSchema
    
    /// Path hashes for state update compression.
    /// Maps normalized path patterns to their FNV-1a 32-bit hashes.
    /// Example: "players.*.position.x" → 0x12345678
    public let pathHashes: [String: UInt32]?
    
    /// Server Event ID → Opcode (Server → Client).
    /// Used for compressing event type strings to integer opcodes.
    public let eventHashes: [String: Int]?
    
    /// Client Event ID → Opcode (Client → Server).
    /// Used for compressing client event type strings to integer opcodes.
    public let clientEventHashes: [String: Int]?
    
    public init(
        stateType: String,
        actions: [String: JSONSchema] = [:],
        clientEvents: [String: JSONSchema] = [:],
        events: [String: JSONSchema] = [:],
        sync: SyncSchema,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil
    ) {
        self.stateType = stateType
        self.actions = actions
        self.clientEvents = clientEvents
        self.events = events
        self.sync = sync
        self.pathHashes = pathHashes
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
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
    /// Whether this type should be treated as atomic (not recursively diffed).
    /// Atomic types are updated as a whole unit, not field-by-field.
    public let atomic: Bool?
    /// Whether this type represents an Optional type (e.g., Optional<PlayerID>).
    public let optional: Bool?
    /// The inner type name for Optional types (e.g., "PlayerID" for Optional<PlayerID>).
    public let innerType: String?
    /// The key type name for Map/Dictionary types (e.g., "Int", "String", "PlayerID").
    public let keyType: String?
    /// For atomic types, the leaf paths in wire order (`AtomicSnapshotValue.atomicLeafPaths`),
    /// e.g. `[["v", "x"], ["v", "y"]]` for Position2.
    public let leafOrder: [[String]]?

    public init(
        nodeKind: NodeKind,
        sync: SyncMetadata? = nil,
        atomic: Bool? = nil,
        optional: Bool? = nil,
        innerType: String? = nil,
        keyType: String? = nil,
        leafOrder: [[String]]? = nil
    ) {
        self.leafOrder = leafOrder
        self.nodeKind = nodeKind
        self.sync = sync
        self.atomic = atomic
        self.optional = optional
        self.innerType = innerType
        self.keyType = keyType
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
