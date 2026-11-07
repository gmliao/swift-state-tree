import Foundation
import SwiftStateTree

/// The op of a merged entry (`[parentId, dynamicKey, op, fieldMask, v1, v2, …]`).
public enum MergedPatchOpcode: Int, Sendable {
    /// Each field is set (as `StatePatchOpcode.set`).
    case set = 4
    /// Each field is added (as `StatePatchOpcode.add`).
    case add = 5
}

/// One entry of an opcode frame: a patch on its own, or patches merged under their parent.
enum FieldMergeEntry {
    case plain(Int)
    /// `members` are patch indices with their bits, in ascending bit order.
    case merged(parentHash: UInt32, dynamicKeys: [String], op: MergedPatchOpcode, members: [(bit: Int, index: Int)])

    /// The mask of a merged entry's members.
    static func mask(_ members: [(bit: Int, index: Int)]) -> UInt32 {
        members.reduce(0) { $0 | (UInt32(1) << UInt32($1.bit)) }
    }
}

enum FieldMergePlan {
    /// The frame's entries. Patches that set (or add) mergeable fields of one parent with the
    /// same dynamic keys and op share an entry, at the position of the first of them; a group of
    /// one stays plain. Deletes, object-level sets and paths outside the schema stay plain.
    ///
    /// Merging moves later members forward, past the patches between them. That is safe only
    /// past a patch that touches none of the group's fields, so a patch at, above or below the
    /// group's parent path (other than a member) closes the group, and later fields of that
    /// parent start a new one: a delete of the entity, or a set of the whole entity, between two
    /// field sets keeps them on either side of it.
    ///
    /// `orderRule: false` drops that rule; only `FieldMergeStatistics` uses it, to count how
    /// often the rule keeps patches apart. Its entries may apply in the wrong order.
    static func entries(
        patches: [StatePatch],
        splits: [(pathHash: UInt32, dynamicKeys: [String], inSchema: Bool)],
        table: FieldMergeTable?,
        orderRule: Bool = true
    ) -> [FieldMergeEntry] {
        guard let table, patches.count > 1 else { return patches.indices.map { .plain($0) } }
        let entries = plan(patches: patches, splits: splits, table: table, orderRule: orderRule)
        if orderRule, FieldMergeStatistics.isEnabled {
            let without = plan(patches: patches, splits: splits, table: table, orderRule: false)
            FieldMergeStatistics.record(patches: patches.count, with: entries, without: without)
        }
        return entries
    }

    private static func plan(
        patches: [StatePatch],
        splits: [(pathHash: UInt32, dynamicKeys: [String], inSchema: Bool)],
        table: FieldMergeTable,
        orderRule: Bool
    ) -> [FieldMergeEntry] {
        struct GroupKey: Hashable {
            let parentHash: UInt32
            let dynamicKeys: [String]
            let op: Int
        }
        final class Group {
            let key: GroupKey
            let parentPath: Substring
            var members: [(bit: Int, index: Int)] = []
            var open = true
            init(key: GroupKey, parentPath: Substring) {
                self.key = key
                self.parentPath = parentPath
            }
        }
        var order: [Either] = []
        enum Either { case plain(Int), group(Group) }
        var openByKey: [GroupKey: Group] = [:]
        var openByParentPath: [Substring: [Group]] = [:]
        /// Open groups by each proper ancestor of their parent path (`/m/a` is under `/m` and
        /// ``): the groups below a path, found without scanning every open group.
        var openBelow: [Substring: [ObjectIdentifier: Group]] = [:]

        /// The proper ancestors of a parent path, `/m/a` → `/m`, ``.
        func ancestors(of parentPath: Substring) -> [Substring] {
            var result: [Substring] = []
            var end = parentPath.endIndex
            while let slash = parentPath[parentPath.startIndex ..< end].lastIndex(of: "/") {
                result.append(parentPath[parentPath.startIndex ..< slash])
                end = slash
            }
            return result
        }
        func open(_ group: Group) {
            openByKey[group.key] = group
            openByParentPath[group.parentPath, default: []].append(group)
            for ancestor in ancestors(of: group.parentPath) {
                openBelow[ancestor, default: [:]][ObjectIdentifier(group)] = group
            }
        }
        func close(_ group: Group) {
            group.open = false
            openByKey[group.key] = nil
            openByParentPath[group.parentPath]?.removeAll { $0 === group }
            if openByParentPath[group.parentPath]?.isEmpty == true { openByParentPath[group.parentPath] = nil }
            for ancestor in ancestors(of: group.parentPath) {
                openBelow[ancestor]?[ObjectIdentifier(group)] = nil
                if openBelow[ancestor]?.isEmpty == true { openBelow[ancestor] = nil }
            }
        }
        /// Closes the open groups whose parent path is `path` or one of its ancestors, except
        /// `keep`; with `ancestorOfParents`, also those below `path`.
        func closeOverlapping(_ path: String, keep: Group?, ancestorOfParents: Bool) {
            if !orderRule || openByParentPath.isEmpty { return }
            var end = path.endIndex
            while true {
                let prefix = path[path.startIndex ..< end]
                if let groups = openByParentPath[prefix] {
                    for group in groups where group !== keep { close(group) }
                }
                guard let slash = path[path.startIndex ..< end].lastIndex(of: "/") else { break }
                end = slash
            }
            if ancestorOfParents, let below = openBelow[path[...]] {
                for group in below.values where group !== keep { close(group) }
            }
        }

        for (index, patch) in patches.enumerated() {
            let op: MergedPatchOpcode?
            switch patch.operation {
            case .set: op = .set
            case .add: op = .add
            case .delete: op = nil
            }
            // A path outside the schema stays plain even if its fallback hash names a field:
            // alone, the encoder refuses it (path index) and the adapter drops and counts it.
            guard let op, splits[index].inSchema, let field = table.field(ofHash: splits[index].pathHash),
                  let slash = patch.path.lastIndex(of: "/") else {
                closeOverlapping(patch.path, keep: nil, ancestorOfParents: true)
                order.append(.plain(index))
                continue
            }
            let key = GroupKey(parentHash: field.parentHash, dynamicKeys: splits[index].dynamicKeys, op: op.rawValue)
            var group = openByKey[key]
            // The same field twice (not expected in a frame): the later one starts a new group.
            if let existing = group, existing.members.contains(where: { $0.bit == field.bit }) {
                close(existing)
                group = nil
            }
            // A field patch can be the parent of another group (an atomic value's leaves).
            closeOverlapping(patch.path, keep: group, ancestorOfParents: field.hasPatternsBelow)
            if group == nil || group?.open == false {
                let created = Group(key: key, parentPath: patch.path[patch.path.startIndex ..< slash])
                open(created)
                order.append(.group(created))
                group = created
            }
            group!.members.append((field.bit, index))
        }
        return order.map { item in
            switch item {
            case .plain(let index):
                return .plain(index)
            case .group(let group):
                if group.members.count == 1 { return .plain(group.members[0].index) }
                return .merged(
                    parentHash: group.key.parentHash,
                    dynamicKeys: group.key.dynamicKeys,
                    op: MergedPatchOpcode(rawValue: group.key.op)!,
                    members: group.members.sorted { $0.bit < $1.bit }
                )
            }
        }
    }
}

/// Opt-in counts of what field merge did to the frames encoded in this process, with the order
/// rule and without it (the second plan only counts; its entries aren't sent). For measurement
/// runs (`EncodingBenchmark --merge-stats`); off, nothing is planned twice.
public enum FieldMergeStatistics {
    public struct Counts: Sendable, Equatable, Codable {
        /// Patches in frames of two or more patches with field merge on.
        public var patches = 0
        /// Their entries, and the patches inside merged entries.
        public var entries = 0
        public var mergedPatches = 0
        /// The same without the order rule.
        public var entriesWithoutOrderRule = 0
        public var mergedPatchesWithoutOrderRule = 0

        public init() {}
    }

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var counts = Counts()
    }
    private static let store = Store()

    /// Read on every frame without a lock: set it before any encoder runs, not during a run.
    nonisolated(unsafe) static var isEnabled = false

    /// Starts (or stops) counting. Not thread-safe: call it before any encoder runs (encoders
    /// read the flag on every frame without a lock), never while frames are being encoded.
    public static func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// The counts since the last call, and resets them.
    public static func take() -> Counts {
        store.lock.lock(); defer { store.lock.unlock() }
        defer { store.counts = Counts() }
        return store.counts
    }

    static func record(patches: Int, with: [FieldMergeEntry], without: [FieldMergeEntry]) {
        func merged(_ entries: [FieldMergeEntry]) -> Int {
            entries.reduce(0) { total, entry in
                if case .merged(_, _, _, let members) = entry { return total + members.count }
                return total
            }
        }
        let mergedWith = merged(with)
        let mergedWithout = merged(without)
        store.lock.lock(); defer { store.lock.unlock() }
        store.counts.patches += patches
        store.counts.entries += with.count
        store.counts.mergedPatches += mergedWith
        store.counts.entriesWithoutOrderRule += without.count
        store.counts.mergedPatchesWithoutOrderRule += mergedWithout
    }
}
