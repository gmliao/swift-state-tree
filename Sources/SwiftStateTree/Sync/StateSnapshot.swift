// Sources/SwiftStateTree/Sync/StateSnapshot.swift

import Foundation

/// Filtered state snapshot (JSON-friendly structure).
public struct StateSnapshot: Equatable, Sendable {
    public var values: [String: SnapshotValue]

    public init(values: [String: SnapshotValue] = [:]) {
        self.values = values
    }
    
    /// Merge values from another snapshot into this one
    /// - Parameter other: The snapshot to merge values from
    /// - Parameter overwrite: If true, values from other will overwrite existing values. Default is true.
    public mutating func merge(_ other: StateSnapshot, overwrite: Bool = true) {
        if overwrite {
            values.merge(other.values) { _, new in new }
        } else {
            values.merge(other.values) { existing, _ in existing }
        }
    }
    
    /// Clear all values
    public mutating func clear() {
        values.removeAll()
    }

    public subscript(_ key: String) -> SnapshotValue? {
        values[key]
    }

    public var isEmpty: Bool {
        values.isEmpty
    }
}

