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
public struct SyncTableField<Node>: @unchecked Sendable {
    public let name: String
    public let policy: PolicyType
    package let kind: SyncTableFieldKind
    /// Why the field takes the fallback, when it does.
    package let fallbackReason: String?
    /// The field's type is or holds a class, so its native last-sent would be the live object.
    fileprivate var holdsReference: Bool = false
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
            holdsReference: syncTableHoldsReference(V.self)
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
        return SyncTableField(name: name, policy: policy, kind: reason == nil ? .node : .fallback, fallbackReason: reason) { builder in
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
        return SyncTableField(name: name, policy: policy, kind: reason == nil ? .optionalNode : .fallback, fallbackReason: reason) { builder in
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
        return SyncTableField(name: name, policy: policy, kind: reason == nil ? .nodeMap : .fallback, fallbackReason: reason) { builder in
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
        SyncTableFieldParts(nested: SyncNodeFieldDiff(name: name, read: read, differ: SyncValueDiffer(convert: convert))) {
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
        if N.hasPlayerDependentSyncFields {
            // Its view without a player is refused (#179); the fallback converts it and so drops it as today.
            return "\(N.self) has player-dependent fields"
        }
        if declaredAtomicType(N.self) != nil {
            // Today's diff replaces an atomic value whole.
            return "\(N.self) is atomic"
        }
        if let field = fields.first(where: { $0.policy != .serverOnly && $0.holdsReference }) {
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

/// Whether `type` is or holds a class, unwrapped as `syncTableHoldsNode` unwraps.
private func syncTableHoldsReference(_ type: Any.Type) -> Bool {
    if type is AnyClass { return true }
    if let optional = type as? any OptionalTypeProbe.Type { return syncTableHoldsReference(optional.wrappedType) }
    if let value = SchemaHelper.dictionaryValueType(from: type) { return syncTableHoldsReference(value) }
    if let element = SchemaHelper.arrayElementType(from: type) { return syncTableHoldsReference(element) }
    return false
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

/// A map key's path component, as today's conversion writes it (`makeKeyString`), for the key
/// types whose components are distinct for distinct keys.
private func syncTableKeyString<K>(_ type: K.Type) -> ((K) -> String)? {
    if K.self == String.self { return { unsafeBitCast($0, to: String.self) } }
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

    func nodeDiffer<N: StateNodeProtocol>(_ type: N.Type) -> SyncNodeDiffer<N> {
        let key = ObjectIdentifier(type)
        if let existing = nodes[key] { return existing as! SyncNodeDiffer<N> }
        let differ = SyncNodeDiffer<N>()
        nodes[key] = differ
        // Filled after it is stored, so a recursive type finds itself.
        differ.fields = (N._syncTableFields() ?? [])
            .filter { $0.policy != .serverOnly }
            .map { $0.build(self).nested }
        return differ
    }
}

/// Diffs two values of `V` into today's patches. The base class is the fallback: it diffs the
/// two values' snapshots every time.
class SyncValueDiffer<V> {
    let convert: (V) throws -> SnapshotValue

    init(convert: @escaping (V) throws -> SnapshotValue) {
        self.convert = convert
    }

    /// Appends the patches from `old` to `new`; returns whether last-sent must take `new` (a
    /// patch, or a map key spelled differently). Otherwise last-sent keeps `old`, which compares
    /// as `new` does.
    func diff(_ new: V, _ old: V, path: String, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> Bool {
        let patches = SyncEngine.diffSnapshotValues(from: try convert(old), to: try convert(new), basePath: path, layout: layout)
        out += patches
        return !patches.isEmpty
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

    override func diff(_ new: V, _ old: V, path: String, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> Bool {
        if equal(new, old) {
            if checksContract, !SnapshotValue.sameValue(try convert(new), try convert(old)) {
                SyncTableContract.report("\(V.self) at \(path): == says equal, but the snapshots differ")
            }
            return false
        }
        return try super.diff(new, old, path: path, layout: layout, into: &out)
    }
}

/// One field of a row: reads it on both sides and diffs it.
struct SyncNodeFieldDiff<Node> {
    let name: String
    let component: String
    let diff: (Node, Node, String, AtomicLayoutTable.Node?, inout [StatePatch]) throws -> Bool

    init<V>(name: String, read: @escaping (Node) -> V?, differ: SyncValueDiffer<V>) {
        self.name = name
        self.component = "/" + SyncEngine.escapedPathComponent(name)
        let component = self.component
        self.diff = { new, old, rowPath, rowLayout, out in
            // A field its policy hides from a view without a player is absent on both sides.
            guard let newValue = read(new), let oldValue = read(old) else { return false }
            return try differ.diff(newValue, oldValue, path: rowPath + component, layout: rowLayout?.child(name), into: &out)
        }
    }
}

/// A node: diffed field by field. A row converts as a map element does (`broadcastView`).
final class SyncNodeDiffer<N: StateNodeProtocol>: SyncValueDiffer<N> {
    var fields: [SyncNodeFieldDiff<N>] = []

    init() {
        super.init(convert: { try SnapshotValue.broadcastView(of: $0) })
    }

    override func diff(_ new: N, _ old: N, path: String, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> Bool {
        var write = false
        for field in fields where try field.diff(new, old, path, layout, &out) {
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

    override func diff(_ new: N?, _ old: N?, path: String, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> Bool {
        switch (new, old) {
        case (let new?, let old?):
            return try node.diff(new, old, path: path, layout: layout, into: &out)
        case (nil, nil):
            return false
        default:
            return try super.diff(new, old, path: path, layout: layout, into: &out)
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

    override func diff(_ new: [K: N], _ old: [K: N], path: String, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> Bool {
        var changed: [(key: K, row: N, respelled: Bool)] = []
        var removed: [K] = []
        try diffRows(new, old, path: path, layout: layout, into: &out, changed: &changed, removed: &removed)
        return !changed.isEmpty || !removed.isEmpty
    }

    /// The diff, with the rows to write to the last-sent map: those created, with a patch or
    /// with their key spelled differently, and those removed. A row whose fields all compare
    /// equal keeps its last-sent copy.
    ///
    /// A key on both sides is addressed by its last-sent spelling, and a key whose spelling
    /// changed (an NFC and an NFD form, equal as `String`s, or as the `String` inside a
    /// `PlayerID`) is written again with the live one: today's diff takes the cached spelling and
    /// its cache then takes the new one.
    func diffRows(
        _ new: [K: N],
        _ old: [K: N],
        path: String,
        layout: AtomicLayoutTable.Node?,
        into out: inout [StatePatch],
        changed: inout [(key: K, row: N, respelled: Bool)],
        removed: inout [K]
    ) throws {
        var matched = 0
        for (key, row) in new {
            if let index = old.index(forKey: key) {
                matched += 1
                let (oldKey, oldRow) = old[index]
                let component = keyString(oldKey)
                let rowPath = path + "/" + SyncEngine.escapedPathComponent(component)
                let write = try node.diff(row, oldRow, path: rowPath, layout: layout?.child(component), into: &out)
                let respelled = !component.utf8.elementsEqual(keyString(key).utf8)
                if write || respelled {
                    changed.append((key, row, respelled))
                }
            } else {
                let component = keyString(key)
                let rowPath = path + "/" + SyncEngine.escapedPathComponent(component)
                out.append(StatePatch(path: rowPath, operation: .set(try node.convert(row))))
                changed.append((key, row, false))
            }
        }
        guard matched < old.count else { return }
        for key in old.keys where new[key] == nil {
            out.append(StatePatch(path: path + "/" + SyncEngine.escapedPathComponent(keyString(key)), operation: .delete))
            removed.append(key)
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

    init(name: String) {
        self.name = name
        self.path = "/" + SyncEngine.escapedPathComponent(name)
    }

    /// Seeds last-sent from `state`; throws when the field doesn't convert (it stays unseeded).
    func seed(_ state: State) throws {}

    /// Appends the field's patches; returns the write to last-sent, or nil when there is none.
    func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> (() -> Void)? { nil }

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

    override func seed(_ state: State) throws {
        guard let value = read(state) else { return }
        _ = try differ.convert(value)
        last = syncTableOwnedCopy(value)
    }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> (() -> Void)? {
        guard let value = read(state) else { return nil }
        guard let old = last else {
            out.append(StatePatch(path: path, operation: .set(try differ.convert(value))))
            return { self.last = syncTableOwnedCopy(value) }
        }
        guard try differ.diff(value, old, path: path, layout: layout, into: &out) else { return nil }
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

    override func seed(_ state: State) throws {
        guard let value = read(state) else { return }
        _ = try differ.convert(value)
        last = syncTableOwnedCopy(value)
        seeded = true
    }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> (() -> Void)? {
        guard let value = read(state) else { return nil }
        guard seeded else {
            out.append(StatePatch(path: path, operation: .set(try differ.convert(value))))
            return {
                self.last = syncTableOwnedCopy(value)
                self.seeded = true
            }
        }
        var changed: [(key: K, row: N, respelled: Bool)] = []
        var removed: [K] = []
        try differ.diffRows(value, last, path: path, layout: layout, into: &out, changed: &changed, removed: &removed)
        guard !changed.isEmpty || !removed.isEmpty else { return nil }
        return {
            for (key, row, respelled) in changed {
                // Removed first, so the key takes the live spelling (an update keeps the old one).
                if respelled { self.last.removeValue(forKey: key) }
                self.last[key] = row
            }
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

    override func seed(_ state: State) throws {
        last = try convert(state)
    }

    override var lastSentForTesting: Any? { last }

    override func diff(_ state: State, layout: AtomicLayoutTable.Node?, into out: inout [StatePatch]) throws -> (() -> Void)? {
        guard let value = try convert(state) else { return nil }
        guard let old = last else {
            out.append(StatePatch(path: path, operation: .set(value)))
            return { self.last = value }
        }
        // Takes every extraction, as today's cache does, so a key's spelling follows the live one.
        out += SyncEngine.diffSnapshotValues(from: old, to: value, basePath: path, layout: layout)
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
package struct SyncTableStaged {
    fileprivate var commits: [() -> Void] = []

    package init() {}

    package var isEmpty: Bool { commits.isEmpty }
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
    /// The kind of each broadcast root field (tests).
    package let kinds: [String: SyncTableFieldKind]
    /// Why each fallback field takes it (tests).
    package let fallbackReasons: [String: String]

    package init(prototype: State = State()) {
        layout = AtomicLayoutTable.forState(State.self)
        order = CanonicalPatchOrder.forState(State.self)
        let builder = SyncTableBuilder()
        var kinds: [String: SyncTableFieldKind] = [:]
        var reasons: [String: String] = [:]
        if let fields = State._syncTableFields() {
            for field in fields where field.policy == .broadcast {
                slots.append(field.build(builder).root())
                kinds[field.name] = field.kind
                reasons[field.name] = field.fallbackReason
            }
        } else {
            for field in prototype.getSyncFields() where field.policyType == .broadcast {
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
    }

    /// Seeds every field's last-sent from `state`; a field that doesn't convert is noted and
    /// stays unseeded, so its next diff sets it whole, as today's cache seed leaves it out.
    package func seed(_ state: State, drops: inout ExtractionDrops) {
        for slot in slots {
            do {
                try slot.seed(state)
            } catch {
                drops.note(error, field: slot.name, scope: .broadcast)
            }
        }
    }

    /// The patches from last-sent to `state` for `fields` (nil: every field), in canonical order,
    /// with the writes to last-sent staged.
    package func diff(_ state: State, fields: Set<String>?, drops: inout ExtractionDrops) -> (patches: [StatePatch], staged: SyncTableStaged) {
        var patches: [StatePatch] = []
        var staged = SyncTableStaged()
        for slot in slots where fields?.contains(slot.name) ?? true {
            var fieldPatches: [StatePatch] = []
            do {
                if let commit = try slot.diff(state, layout: layout.root?.child(slot.name), into: &fieldPatches) {
                    staged.commits.append(commit)
                }
                patches += fieldPatches
            } catch {
                drops.note(error, field: slot.name, scope: .broadcast)
            }
        }
        return (order.sorted(patches), staged)
    }

    /// A root field's last-sent value (tests).
    package func lastSentForTesting(_ name: String) -> Any? {
        slots.first { $0.name == name }?.lastSentForTesting
    }

    package func apply(_ staged: SyncTableStaged) {
        for commit in staged.commits { commit() }
    }
}
