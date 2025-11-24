// Sources/SwiftStateTree/Sync/StatePatch.swift

import Foundation

/// Operation type for state patches.
public enum PatchOperation: Equatable, Sendable {
    /// Set a value at the path (creates or updates)
    case set(SnapshotValue)
    /// Delete the value at the path
    case delete
    /// Add a value to an array at the path (future extension)
    case add(SnapshotValue)
}

/// Represents a single change to the state tree at a specific path.
///
/// Paths use JSON Pointer format (RFC 6901), e.g., "/players/alice/hpCurrent"
public struct StatePatch: Equatable, Sendable {
    /// JSON Pointer path to the changed field
    public let path: String
    /// Operation to perform at this path
    public let operation: PatchOperation
    
    public init(path: String, operation: PatchOperation) {
        self.path = path
        self.operation = operation
    }
}

