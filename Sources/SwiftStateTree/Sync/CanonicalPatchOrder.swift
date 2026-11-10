// Sources/SwiftStateTree/Sync/CanonicalPatchOrder.swift
//
// The canonical emit order of a frame's patches (Notes/plans/2026-11-10-flat-state-storage.md,
// section 8): the order per-type tables produce naturally, applied to today's tree path so a
// frame's bytes don't depend on dictionary iteration order.

import Foundation

/// The canonical order of a land's state patches, built once per state type.
///
/// **Tables.** Every `StateNodeProtocol` type reachable from the root is a table. The root is 0,
/// and the rest are numbered in topological order of the type graph (a type holding another,
/// directly or in a collection, comes first), ties broken by the order a depth-first walk first
/// meets them, fields taken in UTF-8 name order. So a parent's table comes before its children's
/// even when a type is reached through several parents. A recursive type has no such order: the
/// types on a cycle follow the rest in first-meeting order. Atomic types, plain structs and
/// collections of values are values, not tables.
///
/// **A patch's sort key** is `(table, chain, field, sub-key path)`:
/// - the table holding the row the patch addresses;
/// - the row's chain from the root: one `(field, key)` pair per node on the way, where a node
///   held directly by a field (not in a collection) has the key `""`, and each collection level
///   beyond the first adds a pair with the field `""`;
/// - the field of that row the patch writes, absent for a set or delete of the row itself;
/// - the components below the field, inside its value.
///
/// Keys compare table first, then component by component in UTF-8 byte order, a prefix first. So
/// a row's own set or delete sorts before its field patches, and its children (in later tables)
/// after both. Fields compare by name: two keys reach the same position only when everything
/// before it is equal, so the field belongs to the same type, and name order is its field
/// number order (`FieldMergeTable`'s bit rank).
///
/// A path that leaves the schema (an unknown field, or below an optional where no pattern
/// matches, #287) keeps the table and field it reached, and the rest is its sub-key path.
package struct CanonicalPatchOrder: Sendable {
    /// What a field or collection element holds.
    package indirect enum Shape: Sendable, Equatable {
        case node(Int)
        case collection(Shape)
        case optional(Shape)
        case value
    }

    /// A node type: its table and its fields' shapes.
    package struct NodeType: Sendable {
        package var fields: [String: Shape]

        package init(fields: [String: Shape]) {
            self.fields = fields
        }
    }

    /// Node types by table ID.
    package let types: [NodeType]

    /// A patch's sort key.
    package struct Key: Sendable, Comparable, CustomStringConvertible {
        package let table: Int
        package let parts: [String]

        package init(table: Int, parts: [String]) {
            self.table = table
            self.parts = parts
        }

        package static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.table != rhs.table { return lhs.table < rhs.table }
            let count = min(lhs.parts.count, rhs.parts.count)
            var index = 0
            while index < count {
                let left = lhs.parts[index], right = rhs.parts[index]
                // By UTF-8 bytes, never `String` equality, which treats NFC and NFD as equal.
                if !left.utf8.elementsEqual(right.utf8) {
                    return left.utf8.lexicographicallyPrecedes(right.utf8)
                }
                index += 1
            }
            return lhs.parts.count < rhs.parts.count
        }

        package var description: String {
            "\(table):" + parts.map { "[\($0)]" }.joined()
        }
    }

    package init(types: [NodeType]) {
        self.types = types
    }

    /// The order for `State`, built on first use and shared.
    package static func forState<State: StateNodeProtocol>(_ stateType: State.Type) -> CanonicalPatchOrder {
        let key = ObjectIdentifier(stateType)
        if let cached = cache.value(for: key) { return cached }
        return cache.insert(build(root: stateType), for: key)
    }

    /// Walks the types from `root`: fields from `getFieldMetadata()`, collections and optionals
    /// unwrapped as the schema converter does.
    package static func build(root: any StateNodeProtocol.Type) -> CanonicalPatchOrder {
        var builder = Builder()
        _ = builder.visit(root)
        return CanonicalPatchOrder(types: builder.topologicallyNumbered())
    }

    private struct Builder {
        var types: [NodeType] = []
        var indexOfType: [ObjectIdentifier: Int] = [:]

        mutating func visit(_ type: any StateNodeProtocol.Type) -> Int {
            let id = ObjectIdentifier(type)
            if let index = indexOfType[id] { return index }
            let index = types.count
            indexOfType[id] = index
            types.append(NodeType(fields: [:]))
            let fields = type.getFieldMetadata().sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            var shapes: [String: Shape] = [:]
            for field in fields {
                shapes[field.name] = shape(of: field.type)
            }
            types[index].fields = shapes
            return index
        }

        /// The types renumbered parents first (Kahn's algorithm, smallest first-meeting index
        /// among the ready types), with the shapes' table references renumbered to match.
        func topologicallyNumbered() -> [NodeType] {
            var children: [Set<Int>] = types.map { type in Set(type.fields.values.compactMap(\.nodeIndex)) }
            for index in children.indices { children[index].remove(index) }
            var parents = [Int](repeating: 0, count: types.count)
            for set in children { for child in set { parents[child] += 1 } }
            var ready: Set<Int> = Set(types.indices.filter { parents[$0] == 0 })
            var ordered: [Int] = []
            while let next = ready.min() {
                ready.remove(next)
                ordered.append(next)
                for child in children[next] {
                    parents[child] -= 1
                    if parents[child] == 0 { ready.insert(child) }
                }
            }
            // Types on a cycle never become ready.
            let placed = Set(ordered)
            ordered += types.indices.filter { !placed.contains($0) }
            var newIndex = [Int](repeating: 0, count: types.count)
            for (position, old) in ordered.enumerated() { newIndex[old] = position }
            return ordered.map { old in
                NodeType(fields: types[old].fields.mapValues { $0.renumbered(newIndex) })
            }
        }

        mutating func shape(of type: Any.Type) -> Shape {
            if declaredAtomicType(type) != nil { return .value }
            if let node = type as? any StateNodeProtocol.Type { return .node(visit(node)) }
            if let optional = type as? any OptionalTypeProbe.Type { return .optional(shape(of: optional.wrappedType)) }
            if let value = SchemaHelper.dictionaryValueType(from: type) { return .collection(shape(of: value)) }
            if let element = SchemaHelper.arrayElementType(from: type) { return .collection(shape(of: element)) }
            return .value
        }
    }

    // MARK: - Keys

    /// One component of a path or of a schema pattern: a literal, or a pattern's `index`-th
    /// dynamic key (`*`).
    package enum Component: Sendable, Equatable {
        case literal(String)
        case dynamic(Int)
    }

    /// A key with its dynamic keys left open: what a schema pattern's paths share.
    package struct Template: Sendable {
        package let table: Int
        package let parts: [Component]

        /// The key for a path of this pattern with these dynamic keys (`PathHasher`'s split).
        /// Nil when `dynamicKeys` is shorter than the pattern needs.
        package func key(dynamicKeys: [String]) -> Key? {
            var resolved: [String] = []
            resolved.reserveCapacity(parts.count)
            for part in parts {
                switch part {
                case .literal(let text):
                    resolved.append(text)
                case .dynamic(let index):
                    guard index < dynamicKeys.count else { return nil }
                    resolved.append(dynamicKeys[index])
                }
            }
            return Key(table: table, parts: resolved)
        }
    }

    /// The sort key of a JSON Pointer path (`/monsters/42/hp`).
    package func key(path: String) -> Key {
        let components = PathHasher.components(of: path).map(Component.literal)
        let template = walk(components)
        // Only literals: every component resolves.
        return template.key(dynamicKeys: [])!
    }

    /// The template of a schema pattern (`monsters.*.hp`), whose `*`s are dynamic keys in order.
    package func template(pattern: String) -> Template {
        var next = 0
        let components: [Component] = pattern.isEmpty ? [] : pattern.split(separator: ".", omittingEmptySubsequences: false).map {
            if $0 == "*" {
                defer { next += 1 }
                return .dynamic(next)
            }
            return .literal(String($0))
        }
        return walk(components)
    }

    private func walk(_ components: [Component]) -> Template {
        var type = 0
        var chain: [Component] = []
        var index = 0
        while index < components.count {
            guard case .literal(let name) = components[index], let shape = types[type].fields[name] else {
                // Not a field of this type: it and the rest are the sub-key path of an unknown field.
                return Template(table: type, parts: chain + components[index...])
            }
            let field = Component.literal(name)
            index += 1
            var current = shape
            var levels = 0
            descend: while true {
                switch current {
                case .optional(let wrapped):
                    current = wrapped
                case .node(let child):
                    // Held directly, or the element of the collection levels already taken.
                    if levels == 0 { chain += [field, .literal("")] }
                    type = child
                    break descend
                case .collection(let element):
                    guard element.holdsNode, index < components.count else {
                        // A collection of values, or the whole collection: a field of this row.
                        return Template(table: type, parts: chain + [field] + components[index...])
                    }
                    chain += [levels == 0 ? field : .literal(""), components[index]]
                    index += 1
                    levels += 1
                    current = element
                case .value:
                    return Template(table: type, parts: chain + [field] + components[index...])
                }
            }
        }
        // The path ends at a row: a set or delete of the row itself.
        return Template(table: type, parts: chain)
    }

    // MARK: - Sorting

    /// The permutation that puts `keys` in canonical order, ties in their original order.
    package static func order(of keys: [Key]) -> [Int] {
        keys.indices.sorted { lhs, rhs in
            if keys[lhs] < keys[rhs] { return true }
            if keys[rhs] < keys[lhs] { return false }
            return lhs < rhs
        }
    }

    /// `patches` in canonical order.
    package func sorted(_ patches: [StatePatch]) -> [StatePatch] {
        guard patches.count > 1 else { return patches }
        let keys = patches.map { key(path: $0.path) }
        return Self.order(of: keys).map { patches[$0] }
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var orders: [ObjectIdentifier: CanonicalPatchOrder] = [:]

        func value(for key: ObjectIdentifier) -> CanonicalPatchOrder? {
            lock.lock()
            defer { lock.unlock() }
            return orders[key]
        }

        /// Keeps the first order stored for `key`, so every encoder of a type shares one.
        func insert(_ order: CanonicalPatchOrder, for key: ObjectIdentifier) -> CanonicalPatchOrder {
            lock.lock()
            defer { lock.unlock() }
            if let existing = orders[key] { return existing }
            orders[key] = order
            return order
        }
    }
}

extension CanonicalPatchOrder.Shape {
    /// The table this shape holds, through optionals and collections.
    var nodeIndex: Int? {
        switch self {
        case .node(let index): return index
        case .optional(let wrapped), .collection(let wrapped): return wrapped.nodeIndex
        case .value: return nil
        }
    }

    func renumbered(_ newIndex: [Int]) -> Self {
        switch self {
        case .node(let index): return .node(newIndex[index])
        case .optional(let wrapped): return .optional(wrapped.renumbered(newIndex))
        case .collection(let wrapped): return .collection(wrapped.renumbered(newIndex))
        case .value: return .value
        }
    }

    /// The shape is a node, possibly optional or inside further collections.
    var holdsNode: Bool {
        switch self {
        case .node: return true
        case .optional(let wrapped), .collection(let wrapped): return wrapped.holdsNode
        case .value: return false
        }
    }
}
