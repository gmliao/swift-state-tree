// Sources/SwiftStateTree/Sync/SnapshotValueHashing.swift
//
// Deterministic hashing of snapshot values, independent of any encoder: the same value hashes
// the same on every platform and run. Used by the sync-output digests (canonical patch lists).
// It is not the state hash, which hashes the JSON encoding of a snapshot; the two are never
// compared with each other.

import Foundation

extension SnapshotValue {
    /// Feeds this value to `hasher`.
    ///
    /// Each kind is tagged, so `.int(1)`, `.double(1)`, `.string("1")` and `.bool(true)` differ.
    /// Object keys are fed in byte-wise UTF-8 order, so key order never matters. Doubles are
    /// fed by bit pattern, with `-0.0` fed as `0.0` and every NaN as one canonical NaN, because
    /// `SnapshotValue`'s `==` treats them as equal (or, for NaN, never decides by payload).
    package func hash(into hasher: inout DeterministicHash.FNV1a64) {
        switch self {
        case .null:
            hasher.combine(byte: 0)
        case .bool(let value):
            hasher.combine(byte: 1)
            hasher.combine(byte: value ? 1 : 0)
        case .int(let value):
            hasher.combine(byte: 2)
            hasher.combine(UInt64(bitPattern: Int64(value)))
        case .double(let value):
            hasher.combine(byte: 3)
            hasher.combine(Self.canonicalBits(value))
        case .string(let value):
            hasher.combine(byte: 4)
            hasher.combine(value)
        case .array(let elements):
            hasher.combine(byte: 5)
            hasher.combine(UInt64(elements.count))
            for element in elements {
                element.hash(into: &hasher)
            }
        case .object(let fields):
            hasher.combine(byte: 6)
            hasher.combine(UInt64(fields.count))
            for key in fields.keys.sorted(by: Self.utf8Less) {
                hasher.combine(key)
                fields[key]!.hash(into: &hasher)
            }
        }
    }

    /// Byte-wise UTF-8 order: unlike `String`'s `<`, it never treats two different keys as
    /// equal, so the order is total.
    package static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func canonicalBits(_ value: Double) -> UInt64 {
        if value.isNaN { return Double.nan.bitPattern }
        if value == 0 { return 0 }
        return value.bitPattern
    }
}
