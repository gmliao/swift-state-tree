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

/// A path's split: its pattern hash, dynamic keys, and whether the pattern matched the path.
typealias FieldMergeSplit = (pathHash: UInt32, dynamicKeys: [String], inSchema: Bool)

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
        splits: [FieldMergeSplit],
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

    /// The frame's canonical order, splits and entries, as `entries(patches:splits:table:)` gives
    /// them for the patches in that order, reusing `cache`, with field merge on or off:
    /// - `order` is the permutation of `patches` into canonical order (`CanonicalFrameOrder`), the
    ///   identity without one. `splits` and the entries' indices are in that order.
    /// - Splits depend only on the path, so the leading patches whose paths match the cache's
    ///   reference frame (in the order given) take its splits instead of being split again. The
    ///   sort keys come from the splits, so a patch is split once.
    /// - With field merge, a frame whose sorted patches start with the same patches as the
    ///   reference's (same paths and ops, in order) resumes the plan from the reference's
    ///   checkpoint instead of planning those patches again. The plan reads only paths, ops and
    ///   splits, never values, so the result is the full plan's, values included from `patches`
    ///   (a recipient's own values at a shared path keep their place).
    static func splitsAndEntries(
        patches: [StatePatch],
        hasher: PathHasher,
        table: FieldMergeTable?,
        cache: FramePrefixCache?,
        order frameOrder: CanonicalFrameOrder? = nil
    ) -> (order: [Int], splits: [FieldMergeSplit], entries: [FieldMergeEntry]) {
        let reference = cache?.reference
        let samePaths = reference.map { commonPathPrefix($0.rawPaths, patches) } ?? 0
        var rawSplits = samePaths > 0 ? Array(reference!.rawSplits[0 ..< samePaths]) : []
        rawSplits.reserveCapacity(patches.count)
        for index in samePaths ..< patches.count { rawSplits.append(split(of: patches[index], hasher: hasher)) }
        if samePaths > 0 { cache?.recordSplitReuse(samePaths) }

        let order = frameOrder?.permutation(patches, splits: rawSplits) ?? Array(patches.indices)
        let sorted = order.map { patches[$0] }
        let splits = order.map { rawSplits[$0] }

        guard let cache, patches.count > 1, !FieldMergeStatistics.isEnabled else {
            return (order, splits, entries(patches: sorted, splits: splits, table: table))
        }
        let rawPaths = patches.map(PatchPathIdentity.init)
        guard let table else {
            cache.reference = FramePrefixCache.Reference(
                rawPaths: rawPaths, rawSplits: rawSplits,
                shapes: sorted.map(PatchShape.init), checkpoint: nil, checkpointCount: 0
            )
            return (order, splits, sorted.indices.map { .plain($0) })
        }
        let shared = reference.map { commonPrefix($0.shapes, sorted) } ?? 0
        if let reference, let checkpoint = reference.checkpoint,
           shared >= reference.checkpointCount, reference.checkpointCount * 2 >= shared {
            // Resume: the first `checkpointCount` sorted patches match the reference's.
            cache.recordResume()
            var planner = checkpoint
            for index in reference.checkpointCount ..< sorted.count {
                planner.add(index, sorted[index], splits[index])
            }
            return (order, splits, planner.entries())
        }
        // Plan in full; keep a checkpoint where this frame stops matching the reference, for
        // the next frame that matches this one that far (the next recipient of a broadcast).
        var planner = FieldMergePlanner(table: table, orderRule: true)
        var checkpoint: FieldMergePlanner?
        for index in sorted.indices {
            if index == shared, shared >= 2 { checkpoint = planner }
            planner.add(index, sorted[index], splits[index])
        }
        if shared == sorted.count { checkpoint = planner }
        cache.reference = FramePrefixCache.Reference(
            rawPaths: rawPaths, rawSplits: rawSplits,
            shapes: sorted.map(PatchShape.init), checkpoint: checkpoint, checkpointCount: shared
        )
        return (order, splits, planner.entries())
    }

    /// A patch's split: the one it carries when the diff that made it walked this hasher's trie
    /// (`StatePatch.split`), the hasher's own otherwise. A carried split is the hasher's result
    /// for the same path; debug builds check that.
    static func split(of patch: StatePatch, hasher: PathHasher) -> FieldMergeSplit {
        guard let carried = patch.split, carried.belongs(to: hasher) else {
            return hasher.splitReportingMatch(patch.path)
        }
        #if DEBUG
        // The DEBUG reader of the path, apart from the production ones (`pathRebuilds`).
        let path = patch.debugRebuiltPath
        let own = hasher.splitReportingMatch(path)
        assert(
            own.inSchema && own.pathHash == carried.pathHash && own.dynamicKeys == carried.dynamicKeys,
            "carried split of \(path) differs from the hasher's"
        )
        #endif
        return (carried.pathHash, carried.dynamicKeys, true)
    }

    /// How many leading patches have the same path (byte for byte) in both frames.
    private static func commonPathPrefix(_ lhs: [PatchPathIdentity], _ rhs: [StatePatch]) -> Int {
        let count = min(lhs.count, rhs.count)
        var index = 0
        while index < count, lhs[index].matches(rhs[index]) { index += 1 }
        return index
    }

    /// How many leading patches have the same path (byte for byte) and op kind in both frames.
    private static func commonPrefix(_ lhs: [PatchShape], _ rhs: [StatePatch]) -> Int {
        let count = min(lhs.count, rhs.count)
        var index = 0
        while index < count, lhs[index].matches(rhs[index]) { index += 1 }
        return index
    }

    private static func plan(
        patches: [StatePatch],
        splits: [FieldMergeSplit],
        table: FieldMergeTable,
        orderRule: Bool
    ) -> [FieldMergeEntry] {
        var planner = FieldMergePlanner(table: table, orderRule: orderRule)
        for index in patches.indices { planner.add(index, patches[index], splits[index]) }
        return planner.entries()
    }
}

/// The last frame an encoder encoded: its splits and, with field merge, the plan's state partway
/// through it. Shared by the recipients of one sync, whose frames start with the same broadcast
/// patches; recipients encoded concurrently only split and plan more often, never differently.
final class FramePrefixCache: @unchecked Sendable {
    struct Reference {
        /// The frame's paths and their splits, in the order the frame was given (split reuse).
        let rawPaths: [PatchPathIdentity]
        let rawSplits: [FieldMergeSplit]
        /// The frame's paths and op kinds in canonical order: what the plan reads, without the
        /// values.
        let shapes: [PatchShape]
        /// The plan after its first `checkpointCount` patches, when that is worth keeping.
        let checkpoint: FieldMergePlanner?
        let checkpointCount: Int
    }

    private let lock = NSLock()
    private var stored: Reference?
    private var resumeCount = 0
    private var reusedSplitCount = 0

    /// How many plans resumed from a checkpoint, and how many splits were reused (tests).
    var resumes: Int { lock.withLock { resumeCount } }
    var reusedSplits: Int { lock.withLock { reusedSplitCount } }
    func recordResume() { lock.withLock { resumeCount += 1 } }
    func recordSplitReuse(_ count: Int) { lock.withLock { reusedSplitCount += count } }

    var reference: Reference? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A patch's path as the frame cache compares it, byte for byte (#392): a split-only patch by
/// its split, so a frame of them is compared without building their paths; any other patch
/// (`.path`, or the stored pair of a lossy literal) by its string's bytes.
enum PatchPathIdentity {
    case split(PatchSplit)
    case path(String)

    init(_ patch: StatePatch) {
        if patch.isSplitOnly, let split = patch.split {
            self = .split(split)
        } else {
            self = .path(patch.path)
        }
    }

    /// Whether `patch`'s path has the same bytes. Two split-only patches of one hasher: the
    /// same pattern (the same literals, spelled as the trie spells them) and each key's bytes
    /// equal, not merely `String`-equal. A frame that mixes the forms compares bytes.
    func matches(_ patch: StatePatch) -> Bool {
        switch self {
        case .split(let split):
            if patch.isSplitOnly, let other = patch.split, split.hasOwner(of: other) {
                return split.pathHash == other.pathHash
                    && split.dynamicKeys.count == other.dynamicKeys.count
                    && zip(split.dynamicKeys, other.dynamicKeys).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            }
            return split.rebuiltPath().utf8.elementsEqual(patch.path.utf8)
        case .path(let path):
            return path.utf8.elementsEqual(patch.path.utf8)
        }
    }
}

/// A patch's path and op kind.
struct PatchShape {
    let path: PatchPathIdentity
    let op: UInt8

    init(_ patch: StatePatch) {
        path = PatchPathIdentity(patch)
        op = Self.op(patch.operation)
    }

    private static func op(_ operation: PatchOperation) -> UInt8 {
        switch operation {
        case .set: return 0
        case .add: return 1
        case .delete: return 2
        }
    }

    /// The same bytes, not just canonically equivalent: the plan keys paths by their UTF-8 bytes,
    /// and a resumed plan reuses the reference's splits (dynamic keys included).
    func matches(_ patch: StatePatch) -> Bool {
        op == Self.op(patch.operation) && path.matches(patch)
    }
}

/// The plan's state, as a value: a checkpoint is a copy, and resuming one mutates its own copy.
struct FieldMergePlanner {
    /// A path prefix (`/m/a` of `/m/a/hp`) as a dictionary key: hashed once from its UTF-8 bytes
    /// (FNV-1a), compared byte for byte only when the hashes match.
    struct PathKey: Hashable {
        let hash: UInt64
        let path: Substring
        func hash(into hasher: inout Hasher) { hasher.combine(hash) }
        static func == (lhs: PathKey, rhs: PathKey) -> Bool {
            lhs.hash == rhs.hash && lhs.path.utf8.elementsEqual(rhs.path.utf8)
        }
    }
    /// A group's identity: in the schema, the parent path and its pattern fix the dynamic keys.
    struct GroupKey: Hashable {
        let parentHash: UInt32
        let parent: PathKey
        let op: Int
    }
    struct Group {
        let key: GroupKey
        let dynamicKeys: [String]
        /// The proper ancestors of the parent path (`/m/a` → ``, `/m`).
        let ancestors: [PathKey]
        var members: [(bit: Int, index: Int)] = []
        var mask: UInt32 = 0
        var open = true
    }
    enum Item { case plain(Int), group(Int) }

    let table: FieldMergeTable
    let orderRule: Bool
    private var order: [Item] = []
    private var groups: [Group] = []
    private var openByKey: [GroupKey: Int] = [:]
    private var openByParent: [PathKey: [Int]] = [:]
    /// Open groups by each proper ancestor of their parent path: the groups below a path,
    /// found without scanning every open group.
    private var openBelow: [PathKey: Set<Int>] = [:]
    private var cuts: [PathKey] = []

    init(table: FieldMergeTable, orderRule: Bool) {
        self.table = table
        self.orderRule = orderRule
    }

    /// `path`'s prefixes at each `/` and the path itself, shortest first: `/m/a/hp` → ``, `/m`,
    /// `/m/a`, `/m/a/hp`. One pass over the UTF-8 bytes, into `cuts`.
    private mutating func cut(_ path: String) {
        cuts.removeAll(keepingCapacity: true)
        let utf8 = path.utf8
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "/") { cuts.append(PathKey(hash: hash, path: path[path.startIndex ..< index])) }
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            index = utf8.index(after: index)
        }
        cuts.append(PathKey(hash: hash, path: path[...]))
    }

    private mutating func open(_ group: Int) {
        let key = groups[group].key
        openByKey[key] = group
        openByParent[key.parent, default: []].append(group)
        for ancestor in groups[group].ancestors { openBelow[ancestor, default: []].insert(group) }
    }

    private mutating func close(_ group: Int) {
        groups[group].open = false
        let key = groups[group].key
        openByKey[key] = nil
        openByParent[key.parent]?.removeAll { $0 == group }
        if openByParent[key.parent]?.isEmpty == true { openByParent[key.parent] = nil }
        for ancestor in groups[group].ancestors {
            openBelow[ancestor]?.remove(group)
            if openBelow[ancestor]?.isEmpty == true { openBelow[ancestor] = nil }
        }
    }

    /// Closes the open groups whose parent path is the path (`cuts.last`) or one of its
    /// ancestors, except `keep`; with `ancestorOfParents`, also those below the path.
    private mutating func closeOverlapping(keep: Int?, ancestorOfParents: Bool) {
        if !orderRule || openByKey.isEmpty { return }
        for cut in cuts {
            if let open = openByParent[cut] {
                for group in open where group != keep { close(group) }
            }
        }
        if ancestorOfParents, let below = openBelow[cuts[cuts.count - 1]] {
            for group in below where group != keep { close(group) }
        }
    }

    /// Adds patch `index` (in frame order) to the plan.
    mutating func add(_ index: Int, _ patch: StatePatch, _ split: FieldMergeSplit) {
        cut(patch.path)
        let op: MergedPatchOpcode?
        switch patch.operation {
        case .set: op = .set
        case .add: op = .add
        case .delete: op = nil
        }
        // A path outside the schema stays plain even if its fallback hash names a field:
        // alone, the encoder refuses it (path index) and the adapter drops and counts it.
        guard let op, split.inSchema, cuts.count >= 2, let field = table.field(ofHash: split.pathHash) else {
            closeOverlapping(keep: nil, ancestorOfParents: true)
            order.append(.plain(index))
            return
        }
        let key = GroupKey(parentHash: field.parentHash, parent: cuts[cuts.count - 2], op: op.rawValue)
        let bit = UInt32(1) << UInt32(field.bit)
        var group = openByKey[key]
        // The same field twice (not expected in a frame): the later one starts a new group.
        if let existing = group, groups[existing].mask & bit != 0 {
            close(existing)
            group = nil
        }
        // A field patch can be the parent of another group (an atomic value's leaves).
        closeOverlapping(keep: group, ancestorOfParents: field.hasPatternsBelow)
        if let current = group, !groups[current].open { group = nil }
        let target: Int
        if let group {
            target = group
        } else {
            target = groups.count
            groups.append(Group(key: key, dynamicKeys: split.dynamicKeys, ancestors: Array(cuts[0 ..< cuts.count - 2])))
            open(target)
            order.append(.group(target))
        }
        groups[target].members.append((field.bit, index))
        groups[target].mask |= bit
    }

    func entries() -> [FieldMergeEntry] {
        order.map { item in
            switch item {
            case .plain(let index):
                return .plain(index)
            case .group(let id):
                let group = groups[id]
                if group.members.count == 1 { return .plain(group.members[0].index) }
                return .merged(
                    parentHash: group.key.parentHash,
                    dynamicKeys: group.dynamicKeys,
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
