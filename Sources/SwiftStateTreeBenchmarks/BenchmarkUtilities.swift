// Sources/SwiftStateTreeBenchmarks/BenchmarkUtilities.swift

import Foundation
import SwiftStateTree

// MARK: - Timing Utilities

/// Helper to measure execution time
func measureTime(_ block: () throws -> Void) rethrows -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    try block()
    return CFAbsoluteTimeGetCurrent() - start
}

// MARK: - Size Estimation

/// Estimate snapshot size (rough calculation)
func estimateSnapshotSize(_ snapshot: StateSnapshot) -> Int {
    var size = 0
    for (key, value) in snapshot.values {
        size += key.utf8.count
        size += estimateValueSize(value)
    }
    return size
}

func estimateValueSize(_ value: SnapshotValue) -> Int {
    switch value {
    case .null: return 4
    case .bool: return 1
    case .int: return 8
    case .double: return 8
    case .string(let s): return s.utf8.count
    case .array(let arr): return arr.reduce(0) { $0 + estimateValueSize($1) }
    case .object(let obj): return obj.reduce(0) { $0 + $1.key.utf8.count + estimateValueSize($1.value) }
    }
}

/// Estimate the size of a SnapshotValue in bytes (for patch size calculation)
func estimateSnapshotValueSize(_ value: SnapshotValue) -> Int {
    return estimateValueSize(value)
}

