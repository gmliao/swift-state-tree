// Sources/SwiftStateTree/Sync/CanonicalPatchList.swift
//
// The canonical form of one sync scope's patches, for comparing what two sync engines sent
// without comparing encoded bytes (DynamicKeyTable slots, frame order and the wire encoding
// are not canonical). See Notes/plans/2026-11-05-sync-output-replay.md, "Canonical form".

import Foundation

/// One scope's patches in canonical order, with their hash.
///
/// Patches on unrelated paths commute, so their order is not part of the canonical form; the
/// diff produces them in dictionary order (`compareSnapshots` iterates a `Set` of keys), which
/// differs between runs. Patches whose paths are equal or one an ancestor of the other do not
/// commute (`set /a` then `set /a/b` differs from the reverse), so their relative order is kept.
///
/// Canonical order:
/// - group the patches into prefix classes (paths equal or ancestor-related, component-wise);
/// - order the classes by their smallest path, comparing components byte-wise;
/// - keep the original order inside a class.
///
/// The diff is expected never to put two related paths in one scope (`hasPrefixPairs` false).
/// The grouping keeps the hash well-defined if it ever does; the producer asserts it in debug.
package struct CanonicalPatchList: Sendable {
    /// The patches in canonical order.
    package let patches: [StatePatch]
    /// Some class has more than one patch: a path and an ancestor of it (or itself) in one scope.
    package let hasPrefixPairs: Bool

    package init(_ patches: [StatePatch]) {
        let components = patches.map { Self.components(of: $0.path) }
        // A stable sort by components puts each class in one contiguous run, starting at its
        // smallest path: anything after a path that the run's first path is a prefix of, and
        // before the run ends, has that prefix too.
        let order = patches.indices.sorted { lhs, rhs in
            if Self.componentsLess(components[lhs], components[rhs]) { return true }
            if Self.componentsLess(components[rhs], components[lhs]) { return false }
            return lhs < rhs
        }
        var classes: [[Int]] = []
        var root: [Substring] = []
        for index in order {
            if let last = classes.indices.last, Self.isPrefix(root, of: components[index]) {
                classes[last].append(index)
            } else {
                classes.append([index])
                root = components[index]
            }
        }
        // Inside a class the original order counts.
        self.patches = classes.flatMap { $0.sorted() }.map { patches[$0] }
        self.hasPrefixPairs = classes.contains { $0.count > 1 }
    }

    /// One hash over (scope, hash) pairs, sorted by scope byte-wise (UTF-8): the per-player
    /// hash of a sync output, over (player ID, scope hash).
    package static func combinedHash(_ pairs: [(String, UInt64)]) -> UInt64 {
        var hasher = DeterministicHash.FNV1a64()
        hasher.combine(UInt64(pairs.count))
        for (scope, hash) in pairs.sorted(by: { SnapshotValue.utf8Less($0.0, $1.0) }) {
            hasher.combine(scope)
            hasher.combine(hash)
        }
        return hasher.value
    }

    /// FNV-1a 64 over the patches in canonical order: path, operation, value.
    package var hash: UInt64 {
        var hasher = DeterministicHash.FNV1a64()
        hasher.combine(UInt64(patches.count))
        for patch in patches {
            hasher.combine(patch.path)
            switch patch.operation {
            case .set(let value):
                hasher.combine(byte: 1)
                value.hash(into: &hasher)
            case .delete:
                hasher.combine(byte: 2)
            case .add(let value):
                hasher.combine(byte: 3)
                value.hash(into: &hasher)
            }
        }
        return hasher.value
    }

    /// Path components as they appear in the pointer (still escaped: escaping is injective, so
    /// comparing escaped components compares the keys).
    private static func components(of path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { $0 }
    }

    private static func isPrefix(_ prefix: [Substring], of path: [Substring]) -> Bool {
        prefix.count <= path.count && zip(prefix, path).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    private static func componentsLess(_ lhs: [Substring], _ rhs: [Substring]) -> Bool {
        // Byte equality, not `Substring ==` (canonical equivalence), so equality and order agree.
        for (left, right) in zip(lhs, rhs) where !left.utf8.elementsEqual(right.utf8) {
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        return lhs.count < rhs.count
    }
}

extension StatePatch {
    /// The patch with every non-finite double (which JSON cannot hold) written in a tagged form,
    /// `{"$nonFinite": "NaN" | "Infinity" | "-Infinity"}`, so a NaN double and the string "NaN"
    /// stay distinct. Diagnostic patch lists in records use it, so they always save; the verifier
    /// compares its replayed patches in the same form.
    package var jsonSafe: StatePatch {
        switch operation {
        case .set(let value): return StatePatch(path: path, operation: .set(value.jsonSafe))
        case .add(let value): return StatePatch(path: path, operation: .add(value.jsonSafe))
        case .delete: return self
        }
    }
}

extension SnapshotValue {
    /// The key of the tagged form `StatePatch.jsonSafe` writes a non-finite double in.
    package static let nonFiniteTag = "$nonFinite"

    /// `StatePatch.jsonSafe` for one value.
    package var jsonSafe: SnapshotValue {
        switch self {
        case .double(let value) where !value.isFinite:
            let name = value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
            return .object([Self.nonFiniteTag: .string(name)])
        case .array(let elements):
            return .array(elements.map(\.jsonSafe))
        case .object(let fields):
            return .object(fields.mapValues(\.jsonSafe))
        default:
            return self
        }
    }

    /// `==`, except that NaN equals NaN (at any depth): a view holding NaN equals itself. As with
    /// `==`, `0.0` equals `-0.0`, so a change between them is no change (the diff sends nothing).
    package static func sameValue(_ lhs: SnapshotValue?, _ rhs: SnapshotValue?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.double(let a)?, .double(let b)?):
            return a == b || (a.isNaN && b.isNaN)
        case (.array(let a)?, .array(let b)?):
            return a.count == b.count && zip(a, b).allSatisfy { sameValue($0, $1) }
        case (.object(let a)?, .object(let b)?):
            return sameFields(a, b)
        default:
            return lhs == rhs
        }
    }

    /// `sameValue` over two objects' fields.
    package static func sameFields(_ lhs: [String: SnapshotValue], _ rhs: [String: SnapshotValue]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { key, value in sameValue(value, rhs[key]) }
    }
}

/// One consumed event, as the events scope of a sync output hashes it.
package struct CanonicalSyncEvent: Sendable, Equatable {
    /// The keeper's output sequence of the event.
    package let sequence: Int64
    package let type: String
    package let payload: SnapshotValue

    package init(sequence: Int64, type: String, payload: SnapshotValue) {
        self.sequence = sequence
        self.type = type
        self.payload = payload
    }

    /// FNV-1a 64 over the events in the order given (consumed order). Not sorted: clients see
    /// the event order, so a reordering must change the hash.
    package static func hash(_ events: [CanonicalSyncEvent]) -> UInt64 {
        var hasher = DeterministicHash.FNV1a64()
        hasher.combine(UInt64(events.count))
        for event in events {
            hasher.combine(UInt64(bitPattern: event.sequence))
            hasher.combine(event.type)
            event.payload.hash(into: &hasher)
        }
        return hasher.value
    }
}
