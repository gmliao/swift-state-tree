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
        prefix.count <= path.count && zip(prefix, path).allSatisfy { $0 == $1 }
    }

    private static func componentsLess(_ lhs: [Substring], _ rhs: [Substring]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        return lhs.count < rhs.count
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
