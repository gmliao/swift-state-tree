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

/// A synced field the typed diff hands to the snapshot diff, and why.
package struct SyncTableFallbackField: Sendable, Equatable {
    /// `Type.field`: the type that declares the field.
    package let field: String
    package let reason: String
}

/// Every field that takes the fallback in a land of `State` on the typed tables, with its reason:
/// the broadcast root fields, and the synced fields of every node type the typed diff walks from
/// them. Each type is listed once, in the order it is reached, its fields by name. A type held
/// only by a fallback field isn't walked: the whole field is listed.
package func syncTableFallbackFields<State: StateNodeProtocol>(of _: State.Type) -> [SyncTableFallbackField] {
    guard let fields = State._syncTableFields() else {
        return [SyncTableFallbackField(field: "\(State.self)", reason: "\(State.self) has no typed field description")]
    }
    var found: [SyncTableFallbackField] = []
    var visited: Set<ObjectIdentifier> = [ObjectIdentifier(State.self)]
    syncTableCollectFallbacks(fields.filter { $0.policy == .broadcast }, visited: &visited, into: &found)
    return found
}

private func syncTableCollectFallbacks<Node>(
    _ fields: [SyncTableField<Node>], visited: inout Set<ObjectIdentifier>, into found: inout [SyncTableFallbackField]
) {
    for field in fields.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
        if let reason = field.fallbackReason {
            found.append(SyncTableFallbackField(field: "\(Node.self).\(field.name)", reason: reason))
            continue
        }
        // A walked field: a node, an optional node or a node map.
        var type = field.valueType
        if let optional = type as? any OptionalTypeProbe.Type { type = optional.wrappedType }
        if let value = SchemaHelper.dictionaryValueType(from: type) { type = value }
        guard let node = type as? any StateNodeProtocol.Type, visited.insert(ObjectIdentifier(type)).inserted else { continue }
        func walk<N: StateNodeProtocol>(_: N.Type) {
            guard let nested = N._syncTableFields() else { return }
            syncTableCollectFallbacks(nested.filter { $0.policy != .serverOnly }, visited: &visited, into: &found)
        }
        walk(node)
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
        Self.order(&segments, from: first, in: &out)
    }

    /// Puts the rows' segments of `out` (from `first` on) in the order of their components.
    private static func order(_ segments: inout [(component: String, start: Int, end: Int)], from first: Int, in out: inout SyncPatchList) {
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

    /// The diff of a root map against its slotted last-sent table (`SyncSlottedTable`), with the
    /// writes to it as `plan`. The patches and their order are `diffRows`'s; each patch at or
    /// below a row also carries the row's slot in its split (`PatchSplit.row`), when the
    /// diff has a path cursor.
    ///
    /// New rows take their slots here, without changing the table: the lowest slots free before
    /// this plan, in the order of the rows' path components, which is the order their sets are
    /// emitted in. A slot this plan frees is not among them (`SyncSlottedTable.plannedSlots`).
    func diffRows(
        _ new: [K: N],
        against table: SyncSlottedTable<K, N>,
        path: String,
        cursor: PathHasher.Cursor?,
        layout: AtomicLayoutTable.Node?,
        into out: inout SyncPatchList,
        plan: inout SyncRowPlan<K, N>
    ) throws {
        let first = out.entries.count
        var segments: [(component: String, start: Int, end: Int)] = []
        var created: [(component: String, entry: Int, key: K, row: N)] = []
        var matched = 0
        for (key, row) in new {
            let start = out.entries.count
            let escaped: String
            if let slot = table.index[key], let oldRow = table.rows[Int(slot)] {
                matched += 1
                let component = keyString(key)
                escaped = SyncEngine.escapedPathComponent(component)
                let rowPath = path + "/" + escaped
                if try node.diff(row, oldRow, path: rowPath, cursor: cursor?.descending(escaped)?.asRow(slot), layout: layout?.child(component), table: node.table, into: &out) {
                    plan.updates.append((slot, row))
                }
            } else {
                escaped = SyncEngine.escapedPathComponent(keyString(key))
                out.append(StatePatch(
                    path: path + "/" + escaped,
                    operation: .set(try node.convert(row)),
                    split: cursor?.descending(escaped)?.split
                ), table: node.table)
                created.append((escaped, start, key, row))
            }
            if out.entries.count > start { segments.append((escaped, start, out.entries.count)) }
        }
        if matched < table.count {
            for index in table.keys.indices {
                guard let key = table.keys[index], new[key] == nil else { continue }
                let slot = Int32(index)
                let escaped = SyncEngine.escapedPathComponent(keyString(key))
                let start = out.entries.count
                out.append(StatePatch(path: path + "/" + escaped, operation: .delete, split: cursor?.descending(escaped)?.asRow(slot).split), table: node.table)
                segments.append((escaped, start, out.entries.count))
                plan.deletes.append(slot)
            }
        }
        if !created.isEmpty {
            // Only the new keys are sorted. Their entries are still where the walk put them.
            if created.count > 1 {
                created.sort { $0.component.utf8.lexicographicallyPrecedes($1.component.utf8) }
            }
            let slots = table.plannedSlots(creating: created.count)
            plan.plannedCreates = created.count
            plan.creates.reserveCapacity(created.count)
            for (row, slot) in zip(created, slots) {
                plan.creates.append((slot, row.key, row.row))
                let patch = out.entries[row.entry].patch
                if let split = patch.split {
                    out.entries[row.entry] = SyncTablePatch(
                        table: node.table,
                        patch: StatePatch(path: patch.path, operation: patch.operation, split: split.asRow(slot, generation: table.plannedGeneration(of: slot)))
                    )
                }
            }
        }
        Self.order(&segments, from: first, in: &out)
    }
}

// MARK: - Slotted last-sent table

/// The writes of one diff to a slotted table, applied by `SyncSlottedTable.commit`.
struct SyncRowPlan<K: Hashable, N> {
    /// Rows on both sides with a patch.
    var updates: [(slot: Int32, row: N)] = []
    /// New rows, with the slots the diff planned for them, in slot order.
    var creates: [(slot: Int32, key: K, row: N)] = []
    /// How many creates the slots were planned for (`SyncSlottedTable.plannedSlots(creating:)`):
    /// `creates.count`, or more once creates were dropped from the plan.
    var plannedCreates = 0
    /// The slots of the rows that are gone.
    var deletes: [Int32] = []

    var isEmpty: Bool { updates.isEmpty && creates.isEmpty && deletes.isEmpty }
}

/// The last-sent rows of a root node map, numbered with small integers (slots) that a later
/// step puts on the wire in place of the rows' keys (`Notes/plans/2026-11-10-row-addressing.md`,
/// sections 1, 2 and 14).
///
/// - A new row takes the lowest free slot; the new rows of one plan take theirs in the order of
///   their path components.
/// - A deleted row's slot is free from the next plan on, never for a row created by the plan
///   that deleted it: a frame lists its creates before its deletes.
/// - A slot's generation goes up each time the slot is taken again.
/// - A table seeded whole numbers its rows from 0 in the order of their path components.
///
/// The table keeps its high-water mark of slots: it is not compacted.
struct SyncSlottedTable<K: Hashable, N> {
    /// By slot; nil where the slot is free.
    private(set) var rows: ContiguousArray<N?> = []
    private(set) var keys: ContiguousArray<K?> = []
    /// How many times each slot was taken.
    private var takes: [UInt32] = []
    /// `String` equality for string keys, so the spellings of one key are one row.
    private(set) var index: [K: Int32] = [:]
    /// The free slots, ascending.
    private(set) var free: [Int32] = []

    init() {}

    /// A table seeded whole: `rows` in the order of their path components take slots 0, 1, ….
    init(seeding rows: [K: N], keyString: (K) -> String) {
        var ordered = rows.map { (component: SyncEngine.escapedPathComponent(keyString($0.key)), key: $0.key, row: $0.value) }
        ordered.sort { $0.component.utf8.lexicographicallyPrecedes($1.component.utf8) }
        self.rows.reserveCapacity(ordered.count)
        keys.reserveCapacity(ordered.count)
        index.reserveCapacity(ordered.count)
        takes = [UInt32](repeating: 1, count: ordered.count)
        for (slot, entry) in ordered.enumerated() {
            self.rows.append(entry.row)
            keys.append(entry.key)
            index[entry.key] = Int32(slot)
        }
    }

    /// The number of rows.
    var count: Int { index.count }

    /// Leaves the row in `slot` out of a seeded table that no client has: the slot is free and
    /// counts as never taken, so the row's later create gets generation 0.
    mutating func leaveOutOfSeed(slot: Int32) {
        let at = Int(slot)
        guard at < rows.count, let key = keys[at] else { return }
        rows[at] = nil
        keys[at] = nil
        takes[at] = 0
        index[key] = nil
        let insertion = free.firstIndex { $0 > slot } ?? free.count
        free.insert(slot, at: insertion)
    }

    /// The generation of the row in `slot`: 0 for the slot's first row.
    func generation(of slot: Int32) -> UInt32 { takes[Int(slot)] &- 1 }

    /// The generation a row created in `slot` by the next plan gets: one more than the slot's
    /// last row's, 0 for a slot never taken.
    func plannedGeneration(of slot: Int32) -> UInt32 {
        Int(slot) < takes.count ? takes[Int(slot)] : 0
    }

    /// The slots `count` new rows of one plan take, in order: the lowest free ones, then new
    /// ones past the end. A function of the committed table alone: a plan computes it without
    /// changing the table, and no slot the same plan frees is in it.
    func plannedSlots(creating count: Int) -> [Int32] {
        var slots = Array(free.prefix(count))
        var next = Int32(rows.count)
        while slots.count < count {
            slots.append(next)
            next += 1
        }
        return slots
    }

    /// Applies a plan: its creates at the slots it planned, then its updates, then its deletes.
    ///
    /// The creates are not allocated again: a later step drops single creates from a plan after
    /// their slots went into the frame, and the rest must stay where the frame put them. A
    /// planned slot left out stays free.
    mutating func commit(_ plan: SyncRowPlan<K, N>) {
        if !plan.creates.isEmpty {
            // The slots this table plans for the plan's creates, or with drops an in-order part
            // of them: a plan made against another state of the table, or one whose slots were
            // allocated again, fails here.
            assert(
                {
                    var planned = plannedSlots(creating: plan.plannedCreates)[...]
                    for create in plan.creates {
                        guard let at = planned.firstIndex(of: create.slot) else { return false }
                        planned = planned[(at + 1)...]
                    }
                    return true
                }(),
                "a plan's creates are at slots planned against this table"
            )
            var tookFree = false
            for create in plan.creates {
                let slot = Int(create.slot)
                // A slot past the end: the ones skipped before it are free.
                while rows.count < slot {
                    free.append(Int32(rows.count))
                    rows.append(nil)
                    keys.append(nil)
                    takes.append(0)
                }
                if slot == rows.count {
                    rows.append(create.row)
                    keys.append(create.key)
                    takes.append(1)
                } else {
                    assert(rows[slot] == nil, "a create takes a free slot")
                    rows[slot] = create.row
                    keys[slot] = create.key
                    takes[slot] &+= 1
                    tookFree = true
                }
                index[create.key] = create.slot
            }
            if tookFree {
                free.removeAll { rows[Int($0)] != nil }
            }
        }
        for update in plan.updates {
            rows[Int(update.slot)] = update.row
        }
        if !plan.deletes.isEmpty {
            for slot in plan.deletes {
                guard let key = keys[Int(slot)] else { continue }
                index.removeValue(forKey: key)
                rows[Int(slot)] = nil
                keys[Int(slot)] = nil
                free.append(slot)
            }
            free.sort()
        }
    }

    /// The rows as the native map they were sent from.
    var dictionary: [K: N] {
        var result: [K: N] = [:]
        result.reserveCapacity(index.count)
        for slot in rows.indices {
            if let key = keys[slot], let row = rows[slot] {
                result[key] = row
            }
        }
        return result
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
    func stageSeed(_ state: State) throws -> SyncStagedWrite? { nil }

    /// Last-sent as a snapshot value, or nil when the field is unseeded: what clients were last
    /// sent for it, as today's broadcast cache holds.
    var lastSentSnapshot: SnapshotValue? { nil }

    /// Appends the field's patches; returns the write to last-sent, or nil when there is none.
    func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> SyncStagedWrite? { nil }

    /// Diffs from nothing emit a create per row (`SyncTableBroadcastDiff.emitsRowCreates`).
    var emitsRowCreates = false

    /// A root node map with a path cursor: its rows are slot-addressed with row entries.
    var isSlotAddressed: Bool { false }

    /// A slot-addressed field's part of a full view: the map's object, then a create per row in
    /// slot order, from the table `staged` stages (`useStaged`) or from last-sent. Nil for any
    /// other field, and for one with nothing to view (unseeded, and not seeded by this plan).
    func viewPatches(staged: SyncStagedRows?, useStaged: Bool) throws -> [StatePatch]? { nil }

    /// For a field this plan seeds by its creates (`{}` plus a create per row): the live form of
    /// those patches, one set of the whole map, for the sync stream's digest. Otherwise nil.
    func liveDigestForm(staged: SyncStagedRows?) -> StatePatch? { nil }

    /// The last-sent value (tests).
    var lastSentForTesting: Any? { nil }

    /// The slot and generation of each row by its key string, for a slotted field (tests).
    var rowSlotsForTesting: [String: SyncRowSlotForTesting]? { nil }
}

/// A row's slot and generation in a slotted last-sent table (tests).
package struct SyncRowSlotForTesting: Equatable, Sendable {
    package let slot: Int32
    package let generation: UInt32

    package init(slot: Int32, generation: UInt32) {
        self.slot = slot
        self.generation = generation
    }
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

    override func stageSeed(_ state: State) throws -> SyncStagedWrite? {
        guard let value = read(state) else { return nil }
        _ = try differ.convert(value)
        return SyncStagedWrite { self.last = syncTableOwnedCopy(value) }
    }

    override var lastSentSnapshot: SnapshotValue? {
        last.flatMap { try? differ.convert($0) }
    }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> SyncStagedWrite? {
        guard let value = read(state) else { return nil }
        guard let old = last else {
            // A node held by the root is a row of its own table; any other value a root field.
            out.append(StatePatch(path: path, operation: .set(try differ.convert(value)), split: cursor?.split), table: differ.ownTable ?? 0)
            return SyncStagedWrite { self.last = syncTableOwnedCopy(value) }
        }
        guard try differ.diff(value, old, path: path, cursor: cursor, layout: layout, table: 0, into: &out) else { return nil }
        return SyncStagedWrite { self.last = syncTableOwnedCopy(value) }
    }

    override var lastSentForTesting: Any? { last }
}

/// A root dictionary of nodes: last-sent is a slotted table, written row by row.
final class SyncNodeMapRootSlot<State, K: Hashable, N: StateNodeProtocol>: SyncRootSlot<State> {
    let read: (State) -> [K: N]?
    let differ: SyncNodeMapDiffer<K, N>
    private(set) var last = SyncSlottedTable<K, N>()
    private(set) var seeded = false

    init(name: String, read: @escaping (State) -> [K: N]?, differ: SyncNodeMapDiffer<K, N>) {
        self.read = read
        self.differ = differ
        super.init(name: name)
    }

    override var isSlotAddressed: Bool { cursor != nil }

    override func stageSeed(_ state: State) throws -> SyncStagedWrite? {
        guard let value = read(state) else { return nil }
        _ = try differ.convert(value)
        guard emitsRowCreates else {
            // Without row entries no view or drop reads the staged rows.
            let table = SyncSlottedTable(seeding: value, keyString: differ.keyString)
            return SyncStagedWrite {
                self.last = table
                self.seeded = true
            }
        }
        let rows = SyncStagedNodeMapRows<K, N>(seed: SyncSlottedTable(seeding: value, keyString: differ.keyString))
        return SyncStagedWrite(rows: rows) {
            // The seed as staged: without the rows a remake dropped from it.
            self.last = rows.seed!
            self.seeded = true
        }
    }

    override var lastSentSnapshot: SnapshotValue? {
        seeded ? try? differ.convert(last.dictionary) : nil
    }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> SyncStagedWrite? {
        guard let value = read(state) else { return nil }
        guard seeded else {
            guard emitsRowCreates, cursor != nil else {
                // The whole map is a field of the root row.
                out.append(StatePatch(path: path, operation: .set(try differ.convert(value)), split: cursor?.split), table: 0)
                return SyncStagedWrite {
                    self.last = SyncSlottedTable(seeding: value, keyString: self.differ.keyString)
                    self.seeded = true
                }
            }
            // Row entries: the map's object, then a create per row, numbered from 0 in the order
            // of the rows' path components (a seed's numbering), so each client binds every row.
            out.append(StatePatch(path: path, operation: .set(.object([:])), split: cursor?.split), table: 0)
            let empty = SyncSlottedTable<K, N>()
            var plan = SyncRowPlan<K, N>()
            try differ.diffRows(value, against: empty, path: path, cursor: cursor, layout: layout, into: &out, plan: &plan)
            let rows = SyncStagedNodeMapRows<K, N>(plan: plan, base: empty)
            rows.liveValue = try differ.convert(value)
            return SyncStagedWrite(rows: rows) {
                var table = empty
                table.commit(rows.plan!)
                self.last = table
                self.seeded = true
            }
        }
        var plan = SyncRowPlan<K, N>()
        try differ.diffRows(value, against: last, path: path, cursor: cursor, layout: layout, into: &out, plan: &plan)
        guard !plan.isEmpty else { return nil }
        guard emitsRowCreates else {
            // Without row entries no view or drop reads the staged rows.
            return SyncStagedWrite { self.last.commit(plan) }
        }
        let rows = SyncStagedNodeMapRows<K, N>(plan: plan, base: nil)
        return SyncStagedWrite(rows: rows) { self.last.commit(rows.plan!) }
    }

    override func viewPatches(staged: SyncStagedRows?, useStaged: Bool) throws -> [StatePatch]? {
        guard let cursor else { return nil }
        let table: SyncSlottedTable<K, N>
        let rows = staged as? SyncStagedNodeMapRows<K, N>
        if let seed = rows?.seed {
            // Seeded by this plan: nothing committed, so every view numbers it the same way.
            table = seed
        } else if useStaged, let rows, let plan = rows.plan {
            var copy = rows.base ?? last
            copy.commit(plan)
            table = copy
        } else if seeded {
            table = last
        } else {
            return nil
        }
        var patches = [StatePatch(path: path, operation: .set(.object([:])), split: cursor.split)]
        patches.reserveCapacity(table.count + 1)
        for slot in table.rows.indices {
            guard let key = table.keys[slot], let row = table.rows[slot] else { continue }
            let escaped = SyncEngine.escapedPathComponent(differ.keyString(key))
            let slot = Int32(slot)
            patches.append(StatePatch(
                path: path + "/" + escaped,
                operation: .set(try differ.node.convert(row)),
                split: cursor.descending(escaped)?.split?.asRow(slot, generation: table.generation(of: slot))
            ))
        }
        return patches
    }

    override func liveDigestForm(staged: SyncStagedRows?) -> StatePatch? {
        guard let value = (staged as? SyncStagedNodeMapRows<K, N>)?.liveValue else { return nil }
        return StatePatch(path: path, operation: .set(value), split: cursor?.split)
    }

    override var lastSentForTesting: Any? { seeded ? last.dictionary : nil }

    override var rowSlotsForTesting: [String: SyncRowSlotForTesting]? {
        guard seeded else { return nil }
        var result: [String: SyncRowSlotForTesting] = [:]
        for (key, slot) in last.index {
            result[differ.keyString(key)] = SyncRowSlotForTesting(slot: slot, generation: last.generation(of: slot))
        }
        return result
    }
}

/// A root slot's staged write: run by the commit. A root node map's also carries its staged rows.
struct SyncStagedWrite {
    var rows: SyncStagedRows?
    let commit: () -> Void

    init(rows: SyncStagedRows? = nil, commit: @escaping () -> Void) {
        self.rows = rows
        self.commit = commit
    }
}

/// A root node map's rows as one plan stages them, reachable until the commit: a row can be
/// dropped from them (`dropRow(slot:)`), and full views read them (`viewPatches`).
class SyncStagedRows {
    /// Drops the row in `slot` from the plan: a create is left out (its slot stays free), an
    /// update's write is discarded (last-sent keeps the row as clients have it), a seed's row is
    /// left out of the seed (its slot free, never taken). A delete carries no value and is kept.
    /// Returns whether the plan held a create, an update or a seed row in `slot`.
    func dropRow(slot: Int32) -> Bool { false }
}

final class SyncStagedNodeMapRows<K: Hashable, N>: SyncStagedRows {
    /// A diff's writes, applied to `base` (an empty table, for a field seeded by its creates) or
    /// to last-sent.
    fileprivate(set) var plan: SyncRowPlan<K, N>?
    fileprivate let base: SyncSlottedTable<K, N>?
    /// A seed's table (no patches came with it).
    fileprivate(set) var seed: SyncSlottedTable<K, N>?
    /// A field seeded by its creates: the whole map, today's form of those patches.
    fileprivate var liveValue: SnapshotValue?

    fileprivate init(plan: SyncRowPlan<K, N>, base: SyncSlottedTable<K, N>?) {
        self.plan = plan
        self.base = base
        self.seed = nil
    }

    fileprivate init(seed: SyncSlottedTable<K, N>) {
        self.plan = nil
        self.base = nil
        self.seed = seed
    }

    override func dropRow(slot: Int32) -> Bool {
        if var seed {
            // A seed's row reaches clients only through full views: leaving it out of the table
            // leaves it out of every view, and the next plan creates it.
            guard Int(slot) < seed.rows.count, seed.rows[Int(slot)] != nil else { return false }
            seed.leaveOutOfSeed(slot: slot)
            self.seed = seed
            return true
        }
        guard var plan else { return false }
        let before = plan.creates.count + plan.updates.count
        plan.creates.removeAll { $0.slot == slot }
        plan.updates.removeAll { $0.slot == slot }
        self.plan = plan
        return plan.creates.count + plan.updates.count < before
    }
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

    override func stageSeed(_ state: State) throws -> SyncStagedWrite? {
        guard let value = try convert(state) else { return nil }
        return SyncStagedWrite { self.last = value }
    }

    override var lastSentSnapshot: SnapshotValue? { last }

    override var lastSentForTesting: Any? { last }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout SyncPatchList) throws -> SyncStagedWrite? {
        guard let value = try convert(state) else { return nil }
        // A fallback field's patches may address rows of any table: the list is sorted as today.
        guard let old = last else {
            out.append(StatePatch(path: path, operation: .set(value)), table: 0)
            out.needsSort = true
            return SyncStagedWrite { self.last = value }
        }
        // Takes every extraction, as today's cache does.
        let patches = SyncEngine.diffSnapshotValues(from: old, to: value, basePath: path, layout: layout)
        for patch in patches { out.append(patch, table: 0) }
        if !patches.isEmpty { out.needsSort = true }
        return SyncStagedWrite { self.last = value }
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
    /// The staged rows of each slot-addressed root field this plan diffed or seeded, by name.
    fileprivate var rows: [String: SyncStagedRows] = [:]
    /// The tables whose diff or seed staged the writes; `apply` checks it in debug builds, since
    /// the compiler no longer does.
    fileprivate var owner: ObjectIdentifier?
    /// A seed is staged: the commit marks the tables seeded.
    fileprivate var seeds = false
    /// The fields this plan seeded: a later seed of the same plan (a joiner's view after the
    /// broadcast diff) leaves them as staged, so a row a remake dropped from a seed stays out.
    fileprivate var seededFields: Set<String> = []
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
        for slot in slots where (fields?.contains(slot.name) ?? true) && !staged.seededFields.contains(slot.name) {
            staged.seededFields.insert(slot.name)
            do {
                if let write = try slot.stageSeed(state) {
                    staged.commits.append(write.commit)
                    if let rows = write.rows { staged.rows[slot.name] = rows }
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
        staged.rows.merge(result.staged.rows) { _, new in new }
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

    /// Row entries (`rowAddressing`): a slot-addressed field diffed from nothing emits the map's
    /// object and a create per row, not one set of the whole map. Off, the patches are today's.
    package var emitsRowCreates = false {
        didSet { for slot in slots { slot.emitsRowCreates = emitsRowCreates } }
    }

    /// The names of the root fields whose rows are slot-addressed (root node maps with a path
    /// cursor), by their path (`/monsters`).
    package var slotAddressedFields: [String: String] {
        Dictionary(uniqueKeysWithValues: slots.filter(\.isSlotAddressed).map { ($0.path, $0.name) })
    }

    /// Drops the row in `slot` of the root field at `path` from the writes `staged` holds
    /// (`SyncStagedRows.dropRow`). Returns whether a create or an update was dropped.
    @discardableResult
    /// `patches` (a broadcast diff) as the sync stream digests them: a field seeded by its creates
    /// (`{}` plus a create per row) as one set of the whole map, today's form, so the digest is
    /// the same with row addressing off or on.
    package func liveDigestForm(of patches: [StatePatch], staged: SyncTableStaged) -> [StatePatch] {
        guard !staged.rows.isEmpty else { return patches }
        var live: [String: StatePatch] = [:]
        for slot in slots where slot.isSlotAddressed {
            if let patch = slot.liveDigestForm(staged: staged.rows[slot.name]) { live[slot.path] = patch }
        }
        guard !live.isEmpty else { return patches }
        var result: [StatePatch] = []
        result.reserveCapacity(patches.count)
        var placed: Set<String> = []
        for patch in patches {
            // The root field's path: `/units` for `/units` and `/units/a/hp`.
            let rest = patch.path.utf8.dropFirst()
            let root = String(patch.path[..<(rest.firstIndex(of: UInt8(ascii: "/")) ?? patch.path.endIndex)])
            guard let replacement = live[root] else {
                result.append(patch)
                continue
            }
            if placed.insert(root).inserted { result.append(replacement) }
        }
        return result
    }

    package func dropRow(path: String, slot: Int32, from staged: SyncTableStaged) -> Bool {
        guard let name = slots.first(where: { $0.path == path })?.name else { return false }
        return staged.rows[name]?.dropRow(slot: slot) ?? false
    }

    /// The slot-addressed fields' part of a full view, by root path: each field's map object and
    /// a create per row in slot order (`SyncRootSlot.viewPatches`). `useStaged`: the tables as
    /// `staged` leaves them (committed, with the plan's creates, updates and deletes); otherwise
    /// last-sent. A field seeded by this plan is its seed either way. A field whose rows don't
    /// convert is left out, and keeps today's patches.
    package func viewPatches(staged: SyncTableStaged, useStaged: Bool) -> [String: [StatePatch]] {
        var result: [String: [StatePatch]] = [:]
        for slot in slots where slot.isSlotAddressed {
            if let patches = try? slot.viewPatches(staged: staged.rows[slot.name], useStaged: useStaged) {
                result[slot.path] = patches
            }
        }
        return result
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
                if let write = try slot.diff(state, layout: layout.root?.child(slot.name), into: &list) {
                    staged.commits.append(write.commit)
                    if let rows = write.rows { staged.rows[slot.name] = rows }
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

    /// The slots of the root field `name`'s rows by key string, or nil when the field is not a
    /// seeded slotted table (tests).
    package func rowSlotsForTesting(_ name: String) -> [String: SyncRowSlotForTesting]? {
        slots.first { $0.name == name }?.rowSlotsForTesting
    }

    package func apply(_ staged: SyncTableStaged) {
        assert(staged.owner == nil || staged.owner == ObjectIdentifier(self), "staged writes applied to tables that didn't make them")
        for commit in staged.commits { commit() }
        if staged.seeds { isSeeded = true }
    }
}
