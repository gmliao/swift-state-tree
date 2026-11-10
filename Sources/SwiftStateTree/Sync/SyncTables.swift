// Sources/SwiftStateTree/Sync/SyncTables.swift
//
// The typed sync diff (Notes/plans/2026-11-10-flat-storage-step2.md): the broadcast diff computed
// on the native state against typed last-sent values, instead of building a SnapshotValue tree of
// every dirty field and diffing it against the cached tree.

import Foundation

/// How the typed diff handles a synced field (step 2 note, section 3).
public enum SyncTableFieldKind: String, Sendable, Equatable {
    /// A node held directly: its fields are diffed one by one.
    case node
    /// An optional node: diffed field by field while present on both sides.
    case optionalNode
    /// A dictionary of nodes keyed by `String`, `Int` or `PlayerID`: diffed row by row.
    case nodeMap
    /// An `Equatable` value holding no node: compared with `==`, and a changed value is diffed
    /// as today.
    case value
    /// Today's diff of the field's two snapshots, every time.
    case fallback
}

/// One synced field of `Node`, as the typed diff sees it. `@StateNodeBuilder` makes one per `@Sync`
/// field with `make(name:policy:read:convert:)`, and overload resolution on the field's static type
/// picks the kind. `read` is the field's view without a player (its policy's
/// `filteredValue(_:for: nil)`), and `convert` is the macro's own conversion of that value, so a
/// value converts exactly as `snapshot(for: nil)` converts it.
///
/// **Contracts** of a field type `T` the typed diff compares with `==`:
/// - `a == b` implies the two values convert to `sameValue` snapshots. Debug builds check it.
/// - Conversion is a function of the value alone: the diff converts the last-sent value again
///   instead of keeping its snapshot.
///
/// **Value semantics:** a synced value must not share mutable state with the live one. The typed
/// diff routes a class, and a collection or node reaching one, to the fallback, but it can't see a
/// class inside a struct, an enum or an existential; such a value mutated in place sends no patch.
public struct SyncTableField<Node>: @unchecked Sendable {
    public let name: String
    public let policy: PolicyType
    package let kind: SyncTableFieldKind
    /// Why the field takes the fallback, when it does.
    package let fallbackReason: String?
    /// The field's static type, walked by `syncTableHoldsReference`.
    fileprivate var valueType: Any.Type
    fileprivate let build: (SyncTableBuilder) -> SyncTableFieldParts<Node>
}

/// A field's differ inside a row, and its root slot when `Node` is the root.
fileprivate struct SyncTableFieldParts<Node> {
    let nested: SyncNodeFieldDiff<Node>
    let root: () -> SyncRootSlot<Node>
}

// MARK: - Registration (called by the macro)

extension SyncTableField {
    /// Any value: an `Equatable` one holding no node is a `.value`; anything else, the fallback.
    public static func make<V>(
        name: String,
        policy: PolicyType,
        read: @escaping (Node) -> V?,
        convert: @escaping (V) throws -> SnapshotValue
    ) -> SyncTableField<Node> {
        let reason: String?
        let equal = syncTableEquality(of: V.self)
        if syncTableHoldsNode(V.self) {
            reason = "\(V.self) holds a state node outside the shapes the typed diff walks"
        } else if syncTableHoldsReference(V.self) {
            // A last-sent reference is the live object: converting it again would see the new value.
            reason = "\(V.self) is or holds a reference type"
        } else if equal == nil {
            reason = "\(V.self) is not Equatable"
        } else {
            reason = nil
        }
        return SyncTableField(
            name: name,
            policy: policy,
            kind: reason == nil ? .value : .fallback,
            fallbackReason: reason,
            valueType: V.self
        ) { _ in
            guard reason == nil, let equal else {
                return fallbackParts(name: name, read: read, convert: convert)
            }
            return parts(name: name, read: read, differ: SyncEquatableDiffer(convert: convert, equal: equal))
        }
    }

    /// A node held directly.
    public static func make<N: StateNodeProtocol>(
        name: String,
        policy: PolicyType,
        read: @escaping (Node) -> N?,
        convert: @escaping (N) throws -> SnapshotValue
    ) -> SyncTableField<Node> {
        let reason = syncTableNodeFallbackReason(N.self)
        return SyncTableField(name: name, policy: policy, kind: reason == nil ? .node : .fallback, fallbackReason: reason, valueType: N.self) { builder in
            guard reason == nil else { return fallbackParts(name: name, read: read, convert: convert) }
            return parts(name: name, read: read, differ: builder.nodeDiffer(N.self))
        }
    }

    /// An optional node.
    public static func make<N: StateNodeProtocol>(
        name: String,
        policy: PolicyType,
        read: @escaping (Node) -> N??,
        convert: @escaping (N?) throws -> SnapshotValue
    ) -> SyncTableField<Node> {
        let reason = syncTableNodeFallbackReason(N.self)
        return SyncTableField(name: name, policy: policy, kind: reason == nil ? .optionalNode : .fallback, fallbackReason: reason, valueType: N?.self) { builder in
            guard reason == nil else { return fallbackParts(name: name, read: read, convert: convert) }
            return parts(name: name, read: read, differ: SyncOptionalNodeDiffer(convert: convert, node: builder.nodeDiffer(N.self)))
        }
    }

    /// A dictionary of nodes.
    public static func make<K: Hashable, N: StateNodeProtocol>(
        name: String,
        policy: PolicyType,
        read: @escaping (Node) -> [K: N]?,
        convert: @escaping ([K: N]) throws -> SnapshotValue
    ) -> SyncTableField<Node> {
        let keyString = syncTableKeyString(K.self)
        let reason = keyString == nil
            ? "key type \(K.self) is not String, Int or PlayerID"
            : syncTableNodeFallbackReason(N.self)
        return SyncTableField(name: name, policy: policy, kind: reason == nil ? .nodeMap : .fallback, fallbackReason: reason, valueType: [K: N].self) { builder in
            guard reason == nil, let keyString else {
                return fallbackParts(name: name, read: read, convert: convert)
            }
            let differ = SyncNodeMapDiffer(convert: convert, keyString: keyString, node: builder.nodeDiffer(N.self))
            let nested = SyncNodeFieldDiff(name: name, read: read, differ: differ)
            return SyncTableFieldParts(nested: nested) {
                SyncNodeMapRootSlot(name: name, read: read, differ: differ)
            }
        }
    }

    private static func parts<V>(name: String, read: @escaping (Node) -> V?, differ: SyncValueDiffer<V>) -> SyncTableFieldParts<Node> {
        SyncTableFieldParts(nested: SyncNodeFieldDiff(name: name, read: read, differ: differ)) {
            SyncValueRootSlot(name: name, read: read, differ: differ)
        }
    }

    /// A fallback field: as a root field, last-sent is its snapshot, as today's cache. Inside a row
    /// its last-sent is the native value, converted again; a node type with a reference-typed
    /// field takes the fallback itself (`syncTableNodeFallbackReason`), so that holds values only.
    private static func fallbackParts<V>(name: String, read: @escaping (Node) -> V?, convert: @escaping (V) throws -> SnapshotValue) -> SyncTableFieldParts<Node> {
        SyncTableFieldParts(nested: SyncNodeFieldDiff(name: name, read: read, differ: SyncFallbackDiffer(convert: convert))) {
            SyncSnapshotRootSlot(name: name) { node in try read(node).map(convert) }
        }
    }
}

// MARK: - Shape checks

/// Why a node type takes the fallback wherever it is held, or nil when the typed diff walks it.
/// Computed once per type; a type met again while its own reason is computed (a recursive type)
/// counts as walked there.
private func syncTableNodeFallbackReason<N: StateNodeProtocol>(_ type: N.Type) -> String? {
    SyncTableNodeReasons.shared.reason(for: type)
}

private final class SyncTableNodeReasons: @unchecked Sendable {
    static let shared = SyncTableNodeReasons()
    private let lock = NSRecursiveLock()
    private var done: [ObjectIdentifier: String?] = [:]
    private var inProgress: Set<ObjectIdentifier> = []

    func reason<N: StateNodeProtocol>(for type: N.Type) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(type)
        if let known = done[key] { return known }
        if inProgress.contains(key) { return nil }
        inProgress.insert(key)
        defer { inProgress.remove(key) }
        let reason = Self.compute(type)
        done[key] = .some(reason)
        return reason
    }

    private static func compute<N: StateNodeProtocol>(_ type: N.Type) -> String? {
        guard let fields = N._syncTableFields() else {
            return "\(N.self) has no typed field description"
        }
        if N.self is AnyClass {
            // A last-sent row would be the live instance (a hand-written conformance: the macro
            // refuses classes).
            return "\(N.self) is a class"
        }
        if N.hasPlayerDependentSyncFields {
            // Its view without a player is refused (#179); the fallback converts it and so drops it as today.
            return "\(N.self) has player-dependent fields"
        }
        if declaredAtomicType(N.self) != nil {
            // Today's diff replaces an atomic value whole.
            return "\(N.self) is atomic"
        }
        if let field = fields.first(where: { $0.policy != .serverOnly && syncTableHoldsReference($0.valueType) }) {
            // Inside a row the field's last-sent is native, and a reference would be the live object.
            return "\(N.self).\(field.name) is or holds a reference type"
        }
        return nil
    }
}

/// Whether `type` is or holds a state node, unwrapped as `CanonicalPatchOrder` unwraps a shape.
package func syncTableHoldsNode(_ type: Any.Type) -> Bool {
    if declaredAtomicType(type) != nil { return false }
    if type is any StateNodeProtocol.Type { return true }
    if let optional = type as? any OptionalTypeProbe.Type { return syncTableHoldsNode(optional.wrappedType) }
    if let value = SchemaHelper.dictionaryValueType(from: type) { return syncTableHoldsNode(value) }
    if let element = SchemaHelper.arrayElementType(from: type) { return syncTableHoldsNode(element) }
    return false
}

/// Whether `type` is or holds a class: through optionals, dictionary values, arrays and sets, and
/// through the synced fields of every node type it reaches, at any depth. A depth-first walk with a visited
/// set, so a recursive type ends and the answer doesn't depend on any cached partial result.
/// A class wrapped in a struct, enum or existential isn't visible here: synced values must have
/// value semantics (the contract on `SyncTableField`).
private func syncTableHoldsReference(_ type: Any.Type) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return syncTableHoldsReference(type, visited: &visited)
}

private func syncTableHoldsReference(_ type: Any.Type, visited: inout Set<ObjectIdentifier>) -> Bool {
    if type is AnyClass { return true }
    if let optional = type as? any OptionalTypeProbe.Type { return syncTableHoldsReference(optional.wrappedType, visited: &visited) }
    if let value = SchemaHelper.dictionaryValueType(from: type) { return syncTableHoldsReference(value, visited: &visited) }
    if let element = SchemaHelper.arrayElementType(from: type) { return syncTableHoldsReference(element, visited: &visited) }
    if let set = type as? any SyncTableSetProbe.Type { return syncTableHoldsReference(set.syncTableElementType, visited: &visited) }
    guard let node = type as? any StateNodeProtocol.Type, visited.insert(ObjectIdentifier(type)).inserted else { return false }
    return syncTableSyncedFieldTypes(node).contains { syncTableHoldsReference($0, visited: &visited) }
}

/// A `Set`'s element type, for `syncTableHoldsReference`.
private protocol SyncTableSetProbe {
    static var syncTableElementType: Any.Type { get }
}

extension Set: SyncTableSetProbe {
    fileprivate static var syncTableElementType: Any.Type { Element.self }
}

private func syncTableSyncedFieldTypes<N: StateNodeProtocol>(_: N.Type) -> [Any.Type] {
    N._syncTableFields()?.filter { $0.policy != .serverOnly }.map(\.valueType) ?? []
}

/// `==` on `V`, when `V` is `Equatable`.
private func syncTableEquality<V>(of type: V.Type) -> ((V, V) -> Bool)? {
    guard let equatable = type as? any Equatable.Type else { return nil }
    func open<E: Equatable>(_: E.Type) -> (V, V) -> Bool {
        // `V` is `E`: the casts are the identity.
        { lhs, rhs in unsafeBitCast(lhs, to: E.self) == unsafeBitCast(rhs, to: E.self) }
    }
    return open(equatable)
}

/// A map key's path component, as the conversion writes it (`makeKeyString`: a `String` in NFC,
/// a `PlayerID` as stored), for the key types whose components are distinct for distinct keys.
private func syncTableKeyString<K>(_ type: K.Type) -> ((K) -> String)? {
    if K.self == String.self { return { SnapshotValue.wireKey(unsafeBitCast($0, to: String.self)) } }
    if K.self == Int.self { return { String(unsafeBitCast($0, to: Int.self)) } }
    if K.self == PlayerID.self { return { unsafeBitCast($0, to: PlayerID.self).rawValue } }
    return nil
}

/// Types whose `==` is known to agree with their snapshots, so the debug check skips them.
private func syncTableEqualityIsExact(_ type: Any.Type) -> Bool {
    type == Int.self || type == String.self || type == Bool.self || type == Double.self
        || type == Float.self || type == Int8.self || type == Int16.self || type == Int32.self
        || type == Int64.self || type == UInt.self || type == UInt8.self || type == UInt16.self
        || type == UInt32.self || type == UInt64.self || type == PlayerID.self
}

/// The check of the `==` contract (debug builds).
package enum SyncTableContract {
    /// Receives a violation; unbound, a violation is an assertion failure.
    @TaskLocal package static var violationHandler: (@Sendable (String) -> Void)?

    static func report(_ message: String) {
        if let handler = violationHandler {
            handler(message)
        } else {
            assertionFailure(message)
        }
    }
}

// MARK: - Differs

/// Builds each node type's differ once, so a type reached twice (or recursively) shares one.
final class SyncTableBuilder {
    private var nodes: [ObjectIdentifier: AnyObject] = [:]
    private let order: CanonicalPatchOrder
    /// A walked node type has no table in the canonical order: the diff's patches are sorted.
    private(set) var hasUnorderedType = false

    init(order: CanonicalPatchOrder) {
        self.order = order
    }

    func nodeDiffer<N: StateNodeProtocol>(_ type: N.Type) -> SyncNodeDiffer<N> {
        let key = ObjectIdentifier(type)
        if let existing = nodes[key] { return existing as! SyncNodeDiffer<N> }
        let table = order.table(of: type)
        if table == nil { hasUnorderedType = true }
        let differ = SyncNodeDiffer<N>(table: table ?? 0)
        nodes[key] = differ
        // Filled after it is stored, so a recursive type finds itself. In the canonical order's
        // field order (UTF-8 bytes of the path component), so the walk emits in that order.
        differ.fields = (N._syncTableFields() ?? [])
            .filter { $0.policy != .serverOnly }
            .map { $0.build(self).nested }
            .sorted { $0.component.utf8.lexicographicallyPrecedes($1.component.utf8) }
        return differ
    }
}

/// Tests: sort every typed diff's patches with `CanonicalPatchOrder.sorted` instead of relying on
/// the walk's order, to compare the two.
package enum SyncTableOrderForTesting {
    @TaskLocal package static var sorts = false
}

/// A patch with the canonical order's table of the row it addresses (`CanonicalPatchOrder`).
struct SyncTablePatch {
    let table: Int
    let patch: StatePatch
}

/// The patches of one diff, in the order the walk emits them. The walk visits root fields, a
/// row's fields and a map's changed rows in the canonical order's component order, and emits a
/// row's own set or delete before its fields, so the patches of each table come out in canonical
/// order; grouping them by table, in table order and without reordering inside a table
/// (`canonical(tableCount:)`), gives the frame's order without comparing or parsing a path.
struct SyncPatchList {
    var entries: [SyncTablePatch] = []
    /// A fallback field emitted: its patches' tables aren't known here, so the list is sorted
    /// by `CanonicalPatchOrder.sorted`, as today.
    var needsSort = false

    mutating func append(_ patch: StatePatch, table: Int) {
        entries.append(SyncTablePatch(table: table, patch: patch))
    }

    /// The patches grouped by table, tables in order, each table's patches in emit order.
    func canonical(tableCount: Int) -> [StatePatch] {
        guard entries.count > 1 else { return entries.map(\.patch) }
        var starts = [Int](repeating: 0, count: tableCount + 1)
        for entry in entries { starts[min(entry.table, tableCount - 1) + 1] += 1 }
        for table in 1...tableCount { starts[table] += starts[table - 1] }
        var result = [StatePatch?](repeating: nil, count: entries.count)
        for entry in entries {
            let table = min(entry.table, tableCount - 1)
            result[starts[table]] = entry.patch
            starts[table] += 1
        }
        return result.map { $0! }
    }
}

/// Diffs two values of `V` into today's patches. The base class is the fallback: it diffs the
/// two values' snapshots every time.
class SyncValueDiffer<V> {
    let convert: (V) throws -> SnapshotValue

    init(convert: @escaping (V) throws -> SnapshotValue) {
        self.convert = convert
    }

    /// The table of the row a patch at this value's own path addresses, when the value is a row
    /// (a node, present or not); nil for a value, which is a field of the row holding it.
    var ownTable: Int? { nil }

    /// Appends the patches from `old` to `new`; returns whether last-sent must take `new` (it
    /// has a patch). Otherwise last-sent keeps `old`, which compares
    /// as `new` does.
    ///
    /// `cursor` is `path`'s position in the encoder's path trie, when there is one: patches then
    /// carry their split (`StatePatch.split`).
    ///
    /// `table` is the table of the row that holds this value: its patches are that row's field
    /// patches, ordered by the components below the field.
    func diff(_ new: V, _ old: V, path: String, cursor: PathHasher.Cursor?, layout: AtomicLayoutTable.Node?, table: Int, into out: inout SyncPatchList) throws -> Bool {
        var patches = SyncEngine.diffSnapshotValues(from: try convert(old), to: try convert(new), basePath: path, layout: layout)
        if patches.count > 1 {
            // Inside one value the order is by the path below it, component by component.
            patches = syncTableSortedBelow(path, patches)
        }
        for patch in patches {
            let split = cursor?.split(of: patch.path, under: path)
            out.append(split == nil ? patch : StatePatch(path: patch.path, operation: patch.operation, split: split), table: table)
        }
        return !patches.isEmpty
    }
}

/// `patches`, all at `base` or below it, ordered by their components below `base` in UTF-8 byte
/// order, a prefix first: the canonical order's sub-key rule.
private func syncTableSortedBelow(_ base: String, _ patches: [StatePatch]) -> [StatePatch] {
    let skip = base.utf8.count
    let keys = patches.map { patch in
        patch.path.utf8.dropFirst(skip).split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    }
    func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
        let left = keys[lhs], right = keys[rhs]
        var index = 0
        while index < left.count, index < right.count {
            if !left[index].elementsEqual(right[index]) {
                return left[index].lexicographicallyPrecedes(right[index])
            }
            index += 1
        }
        return left.count != right.count ? left.count < right.count : lhs < rhs
    }
    var inOrder = true
    for index in patches.indices.dropFirst() where precedes(index, index - 1) {
        inOrder = false
        break
    }
    if inOrder { return patches }
    return patches.indices.sorted(by: precedes).map { patches[$0] }
}

/// A fallback field inside a row: today's diff of its two snapshots. Its patches may address rows
/// of other tables (a node type the typed diff doesn't walk), so the list is sorted as today.
final class SyncFallbackDiffer<V>: SyncValueDiffer<V> {
    override func diff(_ new: V, _ old: V, path: String, cursor: PathHasher.Cursor?, layout: AtomicLayoutTable.Node?, table: Int, into out: inout SyncPatchList) throws -> Bool {
        let wrote = try super.diff(new, old, path: path, cursor: cursor, layout: layout, table: table, into: &out)
        if wrote { out.needsSort = true }
        return wrote
    }
}

/// An `Equatable` value: `==` first, and today's diff of the two snapshots when they differ.
final class SyncEquatableDiffer<V>: SyncValueDiffer<V> {
    let equal: (V, V) -> Bool
    let checksContract: Bool

    init(convert: @escaping (V) throws -> SnapshotValue, equal: @escaping (V, V) -> Bool) {
        self.equal = equal
        #if DEBUG
        self.checksContract = !syncTableEqualityIsExact(V.self)
        #else
        self.checksContract = false
        #endif
        super.init(convert: convert)
    }

    override func diff(_ new: V, _ old: V, path: String, cursor: PathHasher.Cursor?, layout: AtomicLayoutTable.Node?, table: Int, into out: inout SyncPatchList) throws -> Bool {
        if equal(new, old) {
            if checksContract, !SnapshotValue.sameValue(try convert(new), try convert(old)) {
                SyncTableContract.report("\(V.self) at \(path): == says equal, but the snapshots differ")
            }
            return false
        }
        return try super.diff(new, old, path: path, cursor: cursor, layout: layout, table: table, into: &out)
    }
}

/// One field of a row: reads it on both sides and diffs it.
struct SyncNodeFieldDiff<Node> {
    let name: String
    let component: String
    /// (new row, old row, row path, row cursor, row layout, the row's table, out)
    let diff: (Node, Node, String, PathHasher.Cursor?, AtomicLayoutTable.Node?, Int, inout SyncPatchList) throws -> Bool

    init<V>(name: String, read: @escaping (Node) -> V?, differ: SyncValueDiffer<V>) {
        self.name = name
        self.component = "/" + SyncEngine.escapedPathComponent(name)
        let component = self.component
        let escaped = String(component.dropFirst())
        self.diff = { new, old, rowPath, rowCursor, rowLayout, rowTable, out in
            // A field its policy hides from a view without a player is absent on both sides.
            guard let newValue = read(new), let oldValue = read(old) else { return false }
            return try differ.diff(
                newValue, oldValue,
                path: rowPath + component, cursor: rowCursor?.descending(escaped),
                layout: rowLayout?.child(name), table: rowTable, into: &out
            )
        }
    }
}

/// A node: diffed field by field. A row converts as a map element does (`broadcastView`).
final class SyncNodeDiffer<N: StateNodeProtocol>: SyncValueDiffer<N> {
    /// In the canonical order's field order (`SyncTableBuilder.nodeDiffer`).
    var fields: [SyncNodeFieldDiff<N>] = []
    /// The table of `N`'s rows in the canonical order.
    let table: Int

    init(table: Int) {
        self.table = table
        super.init(convert: { try SnapshotValue.broadcastView(of: $0) })
    }

    override var ownTable: Int? { table }

    override func diff(_ new: N, _ old: N, path: String, cursor: PathHasher.Cursor?, layout: AtomicLayoutTable.Node?, table _: Int, into out: inout SyncPatchList) throws -> Bool {
        var write = false
        for field in fields where try field.diff(new, old, path, cursor, layout, table, &out) {
            write = true
        }
        return write
    }
}

/// An optional node: field by field while present on both sides; otherwise today's diff of the
/// two snapshots (`null` for nil).
final class SyncOptionalNodeDiffer<N: StateNodeProtocol>: SyncValueDiffer<N?> {
    let node: SyncNodeDiffer<N>

    init(convert: @escaping (N?) throws -> SnapshotValue, node: SyncNodeDiffer<N>) {
        self.node = node
        super.init(convert: convert)
    }

    override var ownTable: Int? { node.table }

    override func diff(_ new: N?, _ old: N?, path: String, cursor: PathHasher.Cursor?, layout: AtomicLayoutTable.Node?, table: Int, into out: inout SyncPatchList) throws -> Bool {
        switch (new, old) {
        case (let new?, let old?):
            return try node.diff(new, old, path: path, cursor: cursor, layout: layout, table: table, into: &out)
        case (nil, nil):
            return false
        default:
            // The row appears or goes: a patch at the row's own path, in the row's table.
            return try super.diff(new, old, path: path, cursor: cursor, layout: layout, table: node.table, into: &out)
        }
    }
}

/// A dictionary of nodes, row by row: a new key is a set of the whole row, a gone key a delete,
/// and a key on both sides is diffed field by field.
final class SyncNodeMapDiffer<K: Hashable, N: StateNodeProtocol>: SyncValueDiffer<[K: N]> {
    let keyString: (K) -> String
    let node: SyncNodeDiffer<N>

    init(convert: @escaping ([K: N]) throws -> SnapshotValue, keyString: @escaping (K) -> String, node: SyncNodeDiffer<N>) {
        self.keyString = keyString
        self.node = node
        super.init(convert: convert)
    }

    override func diff(_ new: [K: N], _ old: [K: N], path: String, cursor: PathHasher.Cursor?, layout: AtomicLayoutTable.Node?, table _: Int, into out: inout SyncPatchList) throws -> Bool {
        var changed: [(key: K, row: N)] = []
        var removed: [K] = []
        try diffRows(new, old, path: path, cursor: cursor, layout: layout, into: &out, changed: &changed, removed: &removed)
        return !changed.isEmpty || !removed.isEmpty
    }

    /// The diff, with the rows to write to the last-sent map: those created or with a patch, and
    /// those removed. A row whose fields all compare equal keeps its last-sent copy.
    ///
    /// A key's component is the same whichever spelling the live key has (an NFC and an NFD
    /// form are equal as `String`s, and both are written in NFC, #446).
    func diffRows(
        _ new: [K: N],
        _ old: [K: N],
        path: String,
        cursor: PathHasher.Cursor?,
        layout: AtomicLayoutTable.Node?,
        into out: inout SyncPatchList,
        changed: inout [(key: K, row: N)],
        removed: inout [K]
    ) throws {
        // The rows are visited in dictionary order; each row that emits is a segment of `out`,
        // and the segments are put in the order of their path components afterwards. Only rows
        // with a patch are sorted.
        let first = out.entries.count
        var segments: [(component: String, start: Int, end: Int)] = []
        var matched = 0
        for (key, row) in new {
            let start = out.entries.count
            let escaped: String
            if let index = old.index(forKey: key) {
                matched += 1
                let oldRow = old[index].value
                let component = keyString(key)
                escaped = SyncEngine.escapedPathComponent(component)
                let rowPath = path + "/" + escaped
                if try node.diff(row, oldRow, path: rowPath, cursor: cursor?.descending(escaped), layout: layout?.child(component), table: node.table, into: &out) {
                    changed.append((key, row))
                }
            } else {
                escaped = SyncEngine.escapedPathComponent(keyString(key))
                out.append(StatePatch(
                    path: path + "/" + escaped,
                    operation: .set(try node.convert(row)),
                    split: cursor?.descending(escaped)?.split
                ), table: node.table)
                changed.append((key, row))
            }
            if out.entries.count > start { segments.append((escaped, start, out.entries.count)) }
        }
        if matched < old.count {
            for key in old.keys where new[key] == nil {
                let escaped = SyncEngine.escapedPathComponent(keyString(key))
                let start = out.entries.count
                out.append(StatePatch(path: path + "/" + escaped, operation: .delete, split: cursor?.descending(escaped)?.split), table: node.table)
                segments.append((escaped, start, out.entries.count))
                removed.append(key)
            }
        }
        guard segments.count > 1 else { return }
        var inOrder = true
        for index in segments.indices.dropFirst()
        where segments[index].component.utf8.lexicographicallyPrecedes(segments[index - 1].component.utf8) {
            inOrder = false
            break
        }
        guard !inOrder else { return }
        // By the UTF-8 bytes of the component, as the canonical order compares it ("10" before
        // "9").
        segments.sort { $0.component.utf8.lexicographicallyPrecedes($1.component.utf8) }
        let emitted = Array(out.entries[first...])
        out.entries.removeSubrange(first...)
        for segment in segments {
            out.entries.append(contentsOf: emitted[(segment.start - first) ..< (segment.end - first)])
        }
    }
}

// MARK: - Root slots

/// A root field's last-sent value. A commit only ever writes values that converted when they
/// were diffed, so a value that fails to convert stays different from last-sent and is converted
/// (and dropped) again on every later diff of its field, as today.
class SyncRootSlot<State> {
    let name: String
    let path: String
    /// The field's position in the encoder's path trie (`SyncTableBroadcastDiff.init`), or nil:
    /// no path hasher, a field outside its patterns, or a fallback field, whose patches the
    /// encoder splits as today.
    var cursor: PathHasher.Cursor?

    init(name: String) {
        self.name = name
        self.path = "/" + SyncEngine.escapedPathComponent(name)
    }

    /// The write that seeds last-sent from `state`, or nil when the field has no value; throws
    /// when the field doesn't convert (it stays unseeded).
    func stageSeed(_ state: State) throws -> (() -> Void)? { nil }

    /// Last-sent as a snapshot value, or nil when the field is unseeded: what clients were last
    /// sent for it, as today's broadcast cache holds.
    var lastSentSnapshot: SnapshotValue? { nil }

    /// Appends the field's patches; returns the write to last-sent, or nil when there is none.
    func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> (() -> Void)? { nil }

    /// The last-sent value (tests).
    var lastSentForTesting: Any? { nil }
}

/// A root field written as a whole value: a top-level container gets its own copy. Containers
/// nested inside it (and inside a node map's rows) still share their buffers with the live state
/// until the next live write to them copies one; values stay correct under copy-on-write.
final class SyncValueRootSlot<State, V>: SyncRootSlot<State> {
    let read: (State) -> V?
    let differ: SyncValueDiffer<V>
    private(set) var last: V?

    init(name: String, read: @escaping (State) -> V?, differ: SyncValueDiffer<V>) {
        self.read = read
        self.differ = differ
        super.init(name: name)
    }

    override func stageSeed(_ state: State) throws -> (() -> Void)? {
        guard let value = read(state) else { return nil }
        _ = try differ.convert(value)
        return { self.last = syncTableOwnedCopy(value) }
    }

    override var lastSentSnapshot: SnapshotValue? {
        last.flatMap { try? differ.convert($0) }
    }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> (() -> Void)? {
        guard let value = read(state) else { return nil }
        guard let old = last else {
            // A node held by the root is a row of its own table; any other value a root field.
            out.append(StatePatch(path: path, operation: .set(try differ.convert(value)), split: cursor?.split), table: differ.ownTable ?? 0)
            return { self.last = syncTableOwnedCopy(value) }
        }
        guard try differ.diff(value, old, path: path, cursor: cursor, layout: layout, table: 0, into: &out) else { return nil }
        return { self.last = syncTableOwnedCopy(value) }
    }

    override var lastSentForTesting: Any? { last }
}

/// A root dictionary of nodes: rows are written into last-sent one by one, in place.
final class SyncNodeMapRootSlot<State, K: Hashable, N: StateNodeProtocol>: SyncRootSlot<State> {
    let read: (State) -> [K: N]?
    let differ: SyncNodeMapDiffer<K, N>
    private(set) var last: [K: N] = [:]
    private(set) var seeded = false

    init(name: String, read: @escaping (State) -> [K: N]?, differ: SyncNodeMapDiffer<K, N>) {
        self.read = read
        self.differ = differ
        super.init(name: name)
    }

    override func stageSeed(_ state: State) throws -> (() -> Void)? {
        guard let value = read(state) else { return nil }
        _ = try differ.convert(value)
        return {
            self.last = syncTableOwnedCopy(value)
            self.seeded = true
        }
    }

    override var lastSentSnapshot: SnapshotValue? {
        seeded ? try? differ.convert(last) : nil
    }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> (() -> Void)? {
        guard let value = read(state) else { return nil }
        guard seeded else {
            // The whole map is a field of the root row.
            out.append(StatePatch(path: path, operation: .set(try differ.convert(value)), split: cursor?.split), table: 0)
            return {
                self.last = syncTableOwnedCopy(value)
                self.seeded = true
            }
        }
        var changed: [(key: K, row: N)] = []
        var removed: [K] = []
        try differ.diffRows(value, last, path: path, cursor: cursor, layout: layout, into: &out, changed: &changed, removed: &removed)
        guard !changed.isEmpty || !removed.isEmpty else { return nil }
        return {
            for (key, row) in changed { self.last[key] = row }
            for key in removed { self.last.removeValue(forKey: key) }
        }
    }

    override var lastSentForTesting: Any? { seeded ? last : nil }
}

/// A root field the typed diff doesn't describe: today's conversion and diff, with last-sent kept
/// as its snapshot.
final class SyncSnapshotRootSlot<State>: SyncRootSlot<State> {
    private var last: SnapshotValue?
    private let convert: (State) throws -> SnapshotValue?

    init(name: String, convert: @escaping (State) throws -> SnapshotValue?) {
        self.convert = convert
        super.init(name: name)
    }

    override func stageSeed(_ state: State) throws -> (() -> Void)? {
        guard let value = try convert(state) else { return nil }
        return { self.last = value }
    }

    override var lastSentSnapshot: SnapshotValue? { last }

    override var lastSentForTesting: Any? { last }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> (() -> Void)? {
        guard let value = try convert(state) else { return nil }
        // A fallback field's patches may address rows of any table: the list is sorted as today.
        guard let old = last else {
            out.append(StatePatch(path: path, operation: .set(value)), table: 0)
            out.needsSort = true
            return { self.last = value }
        }
        // Takes every extraction, as today's cache does.
        let patches = SyncEngine.diffSnapshotValues(from: old, to: value, basePath: path, layout: layout)
        for patch in patches { out.append(patch, table: 0) }
        if !patches.isEmpty { out.needsSort = true }
        return { self.last = value }
    }
}

/// A top-level container in its own buffer, so a later write to either copy doesn't copy the
/// other. The copy is shallow: nested containers and the fields of nodes are shared.
private func syncTableOwnedCopy<V>(_ value: V) -> V {
    guard let container = value as? any SyncTableOwnedCopy else { return value }
    return container.syncTableOwnedCopy() as! V
}

private protocol SyncTableOwnedCopy {
    func syncTableOwnedCopy() -> Self
}

extension Dictionary: SyncTableOwnedCopy {
    fileprivate func syncTableOwnedCopy() -> Self {
        var copy = Self(minimumCapacity: count)
        for (key, value) in self { copy[key] = value }
        return copy
    }
}

extension Array: SyncTableOwnedCopy {
    fileprivate func syncTableOwnedCopy() -> Self {
        var copy = Self()
        copy.reserveCapacity(count)
        copy.append(contentsOf: self)
        return copy
    }
}

extension Set: SyncTableOwnedCopy {
    fileprivate func syncTableOwnedCopy() -> Self {
        var copy = Self(minimumCapacity: count)
        for element in self { copy.insert(element) }
        return copy
    }
}

// MARK: - The broadcast diff

/// The writes to last-sent of one diff, applied at the sync's commit (`apply(_:)`); dropped on a
/// failed plan.
///
/// `@unchecked Sendable`: the writes capture the tables' slots, which belong to the one owner that
/// made the diff (the adapter). The value only travels inside that owner's sync plan, and only
/// `SyncTableBroadcastDiff.apply(_:)`, called by the same owner, runs the writes.
package struct SyncTableStaged: @unchecked Sendable {
    fileprivate var commits: [() -> Void] = []
    /// The tables whose diff or seed staged the writes; `apply` checks it in debug builds, since
    /// the compiler no longer does.
    fileprivate var owner: ObjectIdentifier?
    /// A seed is staged: the commit marks the tables seeded.
    fileprivate var seeds = false
    /// A sync plan's diff (or its first seed) ran against the tables, with or without a write:
    /// what a staged broadcast cache says about today's path.
    package fileprivate(set) var holdsBroadcastDiff = false

    package init() {}

    package var isEmpty: Bool { commits.isEmpty && !seeds }
}

/// The typed broadcast diff of a land's state: its broadcast root fields' last-sent values, and
/// the diff against them in canonical order (step 2 note, sections 2-4).
///
/// A root field whose conversion throws anywhere in its diff is dropped from that diff as today
/// (`ExtractionDrops`, scope broadcast): none of its patches, none of its writes to last-sent.
package final class SyncTableBroadcastDiff<State: StateNodeProtocol> {
    private var slots: [SyncRootSlot<State>] = []
    private let layout: AtomicLayoutTable
    private let order: CanonicalPatchOrder
    /// The walk can't give the canonical order for this state (a type outside the order, or no
    /// typed field description): every diff's patches are sorted, as today.
    package let alwaysSorts: Bool
    /// A seed was committed: the tables hold what clients were last sent, as a non-nil broadcast
    /// cache does today. A field left out of every seed so far (its conversion threw, or a seed
    /// was limited to other fields) is still unseeded, and its next diff sets it whole.
    package private(set) var isSeeded = false
    /// The kind of each broadcast root field (tests).
    package let kinds: [String: SyncTableFieldKind]
    /// Why each fallback field takes it (tests).
    package let fallbackReasons: [String: String]

    /// `pathCursor` is the root of the path trie of the encoder the patches go to
    /// (`PathHasher.rootCursor`), when it has one: the typed fields' patches then carry their
    /// split, so that encoder doesn't split their paths again.
    package init(prototype: State? = nil, pathCursor: PathHasher.Cursor? = nil) {
        layout = AtomicLayoutTable.forState(State.self)
        order = CanonicalPatchOrder.forState(State.self)
        let builder = SyncTableBuilder(order: order)
        var kinds: [String: SyncTableFieldKind] = [:]
        var reasons: [String: String] = [:]
        if let fields = State._syncTableFields() {
            for field in fields where field.policy == .broadcast {
                let slot = field.build(builder).root()
                if field.kind != .fallback {
                    slot.cursor = pathCursor?.descending(SyncEngine.escapedPathComponent(field.name))
                }
                slots.append(slot)
                kinds[field.name] = field.kind
                reasons[field.name] = field.fallbackReason
            }
        } else {
            // Only a state without a typed field description needs an instance, for its field list.
            for field in (prototype ?? State()).getSyncFields() where field.policyType == .broadcast {
                let only: Set<String> = [field.name]
                slots.append(SyncSnapshotRootSlot<State>(name: field.name) { state in
                    try state.broadcastSnapshot(dirtyFields: only).values[field.name]
                })
                kinds[field.name] = .fallback
                reasons[field.name] = "\(State.self) has no typed field description"
            }
        }
        self.kinds = kinds
        self.fallbackReasons = reasons
        self.alwaysSorts = builder.hasUnorderedType || State._syncTableFields() == nil
        // Root fields in the canonical order's field order, so the walk emits in that order.
        slots.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// Seeds every field's last-sent from `state`; a field that doesn't convert is noted and
    /// stays unseeded, so its next diff sets it whole, as today's cache seed leaves it out.
    package func seed(_ state: State, drops: inout ExtractionDrops) {
        var staged = SyncTableStaged()
        stageSeed(state, fields: nil, drops: &drops, into: &staged)
        apply(staged)
    }

    /// Stages the seed of `fields` (nil: every field) from `state`. Today's cache seed takes the
    /// snapshot a plan extracted, which holds only the plan's dirty fields when it has some, so
    /// the seed is limited the same way.
    package func stageSeed(_ state: State, fields: Set<String>?, drops: inout ExtractionDrops, into staged: inout SyncTableStaged) {
        for slot in slots where fields?.contains(slot.name) ?? true {
            do {
                if let commit = try slot.stageSeed(state) {
                    staged.commits.append(commit)
                }
            } catch {
                drops.note(error, field: slot.name, scope: .broadcast)
            }
        }
        staged.seeds = true
        staged.owner = ObjectIdentifier(self)
    }

    /// A sync plan's broadcast diff, as `SyncEngine.computeBroadcastDiffFromSnapshot` against the
    /// cached baseline: unseeded tables are seeded from `fields` and yield no patch.
    package func planDiff(_ state: State, fields: Set<String>?, drops: inout ExtractionDrops, into staged: inout SyncTableStaged) -> [StatePatch] {
        staged.holdsBroadcastDiff = true
        guard isSeeded else {
            // One diff per plan, before any seed of it: a staged seed isn't visible to a diff.
            assert(!staged.seeds, "a plan's broadcast diff follows a seed staged by the same plan")
            stageSeed(state, fields: fields, drops: &drops, into: &staged)
            return []
        }
        let result = diff(state, fields: fields, drops: &drops)
        staged.commits += result.staged.commits
        staged.owner = ObjectIdentifier(self)
        #if DEBUG
        // The tests' diff fault stands for a bug in the diff that live and replay share: it
        // applies here as it does to the snapshot diff.
        if let fault = SyncEngineDiffFaultForTesting.current {
            return fault(lastSentSnapshot ?? StateSnapshot(values: [:]), result.patches)
        }
        #endif
        return result.patches
    }

    /// What clients were last sent for the root field `name`, or nil when it is unseeded.
    package func lastSentSnapshot(of name: String) -> SnapshotValue? {
        slots.first { $0.name == name }?.lastSentSnapshot
    }

    /// Last-sent as a snapshot of the seeded broadcast fields, or nil before the first seed.
    package var lastSentSnapshot: StateSnapshot? {
        guard isSeeded else { return nil }
        var values: [String: SnapshotValue] = [:]
        for slot in slots {
            values[slot.name] = slot.lastSentSnapshot
        }
        return StateSnapshot(values: values)
    }

    /// The patches from last-sent to `state` for `fields` (nil: every field), in canonical order,
    /// with the writes to last-sent staged.
    package func diff(_ state: State, fields: Set<String>?, drops: inout ExtractionDrops) -> (patches: [StatePatch], staged: SyncTableStaged) {
        var list = SyncPatchList()
        var staged = SyncTableStaged()
        staged.owner = ObjectIdentifier(self)
        for slot in slots where fields?.contains(slot.name) ?? true {
            let emitted = list.entries.count
            let sorts = list.needsSort
            do {
                if let commit = try slot.diff(state, layout: layout.root?.child(slot.name), into: &list) {
                    staged.commits.append(commit)
                }
            } catch {
                // The whole root field is dropped: none of its patches.
                list.entries.removeSubrange(emitted...)
                list.needsSort = sorts
                drops.note(error, field: slot.name, scope: .broadcast)
            }
        }
        if list.needsSort || alwaysSorts || SyncTableOrderForTesting.sorts {
            return (order.sorted(list.entries.map(\.patch)), staged)
        }
        // Already in canonical order within each table: group by table, nothing is compared.
        return (list.canonical(tableCount: max(order.types.count, 1)), staged)
    }


    /// A root field's last-sent value (tests).
    package func lastSentForTesting(_ name: String) -> Any? {
        slots.first { $0.name == name }?.lastSentForTesting
    }

    package func apply(_ staged: SyncTableStaged) {
        assert(staged.owner == nil || staged.owner == ObjectIdentifier(self), "staged writes applied to tables that didn't make them")
        for commit in staged.commits { commit() }
        if staged.seeds { isSeeded = true }
    }
}
