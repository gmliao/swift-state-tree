// Sources/SwiftStateTree/Sync/StateSnapshot.swift

import Foundation

/// Filtered state snapshot (JSON-friendly structure).
public struct StateSnapshot: Equatable, Sendable {
    public let values: [String: SnapshotValue]

    public init(values: [String: SnapshotValue]) {
        self.values = values
    }

    public subscript(_ key: String) -> SnapshotValue? {
        values[key]
    }

    public var isEmpty: Bool {
        values.isEmpty
    }
}

