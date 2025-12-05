// Sources/SwiftStateTree/Sync/StatePatch.swift

import Foundation

/// Operation type for state patches.
///
/// Maps to JSON Patch operations (RFC 6902):
/// - `.set` -> "replace" or "add" (depending on path existence)
/// - `.delete` -> "remove"
/// - `.add` -> "add" (for array operations)
public enum PatchOperation: Equatable, Sendable, Codable {
    /// Set a value at the path (creates or updates)
    case set(SnapshotValue)
    /// Delete the value at the path
    case delete
    /// Add a value to an array at the path (future extension)
    case add(SnapshotValue)
    
    /// JSON Patch operation string (RFC 6902)
    var jsonPatchOp: String {
        switch self {
        case .set:
            return "replace" // or "add" depending on context
        case .delete:
            return "remove"
        case .add:
            return "add"
        }
    }
    
    /// Encode as JSON Patch format
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .set(let value):
            // For JSON Patch, we encode as an object with "op", "path", "value"
            // But since this is just the operation, we'll encode the value
            try container.encode(value)
        case .delete:
            // Delete operation doesn't need a value
            try container.encodeNil()
        case .add(let value):
            try container.encode(value)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .delete
        } else {
            let value = try container.decode(SnapshotValue.self)
            self = .set(value)
        }
    }
}

/// Represents a single change to the state tree at a specific path.
///
/// Paths use JSON Pointer format (RFC 6901), e.g., "/players/alice/hpCurrent"
/// Serializes to JSON Patch format (RFC 6902) for transport:
/// ```json
/// {
///   "op": "replace",
///   "path": "/players/alice/hpCurrent",
///   "value": 100
/// }
/// ```
public struct StatePatch: Equatable, Sendable, Codable {
    /// JSON Pointer path to the changed field
    public let path: String
    /// Operation to perform at this path
    public let operation: PatchOperation
    
    public init(path: String, operation: PatchOperation) {
        self.path = path
        self.operation = operation
    }
    
    /// Encode as JSON Patch format (RFC 6902)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        
        switch operation {
        case .set(let value):
            try container.encode("replace", forKey: .op)
            try container.encode(value, forKey: .value)
        case .delete:
            try container.encode("remove", forKey: .op)
            // "remove" operation doesn't include "value"
        case .add(let value):
            try container.encode("add", forKey: .op)
            try container.encode(value, forKey: .value)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        let op = try container.decode(String.self, forKey: .op)
        
        switch op {
        case "replace", "add":
            let value = try container.decode(SnapshotValue.self, forKey: .value)
            operation = op == "add" ? .add(value) : .set(value)
        case "remove":
            operation = .delete
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op,
                in: container,
                debugDescription: "Unknown JSON Patch operation: \(op)"
            )
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case op
        case path
        case value
    }
}

