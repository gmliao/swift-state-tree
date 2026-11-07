import Foundation

/// The atomic values of one state type: path pattern → leaf paths, built from the state's schema.
///
/// A path is atomic exactly when its value's type conforms to `AtomicSnapshotValue` (seeing
/// through one `Optional`); nothing is guessed from a value's shape or a type's name. Patterns use
/// the path-hash form, with `*` for a map key or array index (`units.*.position`).
///
/// `SyncEngine(for:)` takes its table from `forState(_:)`, which builds it once per state type and
/// caches it, so an engine can't exist without the real table (no registration is needed).
public struct AtomicLayoutTable: Sendable {
    /// A declared leaf list that doesn't match the type's schema properties.
    public struct BuildError: Error, Equatable, CustomStringConvertible {
        /// The atomic type's schema name.
        public let typeName: String
        /// Leaf paths of the schema that the declaration leaves out.
        public let missing: [[String]]
        /// Declared leaf paths that the schema doesn't have.
        public let extra: [[String]]

        public var description: String {
            "AtomicSnapshotValue \(typeName): atomicLeafPaths doesn't match its properties"
                + " (missing \(missing.map { $0.joined(separator: ".") }),"
                + " extra \(extra.map { $0.joined(separator: ".") }))"
        }
    }

    /// One schema position on the way to an atomic value. A recursive type points back to the
    /// node of its own definition, so the graph can have cycles.
    ///
    /// Filled only while the table is built (`Builder`), immutable afterwards; that is what makes
    /// the unchecked `Sendable` sound.
    package final class Node: @unchecked Sendable {
        fileprivate(set) var children: [String: Node]
        fileprivate(set) var wildcard: Node?
        /// Set when the value at this position is atomic.
        package let leafPaths: [[String]]?

        init(children: [String: Node] = [:], wildcard: Node? = nil, leafPaths: [[String]]?) {
            self.children = children
            self.wildcard = wildcard
            self.leafPaths = leafPaths
        }

        fileprivate var isEmpty: Bool { leafPaths == nil && children.isEmpty && wildcard == nil }

        /// The position of the child under `key`: a named property, else the map key / index.
        @inline(__always)
        package func child(_ key: String) -> Node? {
            children[key] ?? wildcard
        }

        package var isAtomic: Bool { leafPaths != nil }
    }

    /// The root position (the state's fields), or `nil` when the state holds no atomic value.
    package let root: Node?
    /// Every atomic path pattern with its leaf paths in wire order.
    public let patterns: [String: [[String]]]

    // MARK: - Building

    /// Builds the table of `State` from its schema, checking every declared leaf list.
    public static func build<State: StateNodeProtocol>(for stateType: State.Type) throws -> AtomicLayoutTable {
        var definitions: [String: JSONSchema] = [:]
        var visited: Set<String> = []
        let rootSchema = TypeToSchemaConverter.convert(
            stateType, definitions: &definitions, visitedTypes: &visited
        )
        var builder = Builder(definitions: definitions)
        let root = try builder.node(for: rootSchema)
        var patterns: [String: [[String]]] = [:]
        if let root {
            collectPatterns(root, path: [], onPath: [:], into: &patterns)
        }
        return AtomicLayoutTable(root: root, patterns: patterns)
    }

    /// Every atomic position reachable from `node`; a recursive type is listed through one
    /// level of its recursion (`tree.pos`, `tree.children.*.pos`), and the diff follows it to
    /// any depth.
    private static func collectPatterns(
        _ node: Node, path: [String], onPath: [ObjectIdentifier: Int], into patterns: inout [String: [[String]]]
    ) {
        if let leafPaths = node.leafPaths {
            patterns[path.joined(separator: ".")] = leafPaths
            return
        }
        let id = ObjectIdentifier(node)
        let seen = onPath[id, default: 0]
        guard seen < 2 else { return }
        var onPath = onPath
        onPath[id] = seen + 1
        for (name, child) in node.children {
            collectPatterns(child, path: path + [name], onPath: onPath, into: &patterns)
        }
        if let wildcard = node.wildcard {
            collectPatterns(wildcard, path: path + ["*"], onPath: onPath, into: &patterns)
        }
    }

    /// The table of `State`, built on first use and cached per type. A declaration that doesn't
    /// match its schema is a programming error and traps here, before anything is sent.
    public static func forState<State: StateNodeProtocol>(_ stateType: State.Type) -> AtomicLayoutTable {
        let key = ObjectIdentifier(stateType)
        if let cached = cache.value(for: key) {
            return cached
        }
        let table: AtomicLayoutTable
        do {
            table = try build(for: stateType)
        } catch {
            preconditionFailure("AtomicLayoutTable for \(stateType): \(error)")
        }
        return cache.insert(table, for: key)
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [ObjectIdentifier: AtomicLayoutTable] = [:]

        func value(for key: ObjectIdentifier) -> AtomicLayoutTable? {
            lock.lock()
            defer { lock.unlock() }
            return tables[key]
        }

        /// Keeps the first table stored for `key`, so every engine of a type shares one.
        func insert(_ table: AtomicLayoutTable, for key: ObjectIdentifier) -> AtomicLayoutTable {
            lock.lock()
            defer { lock.unlock() }
            if let existing = tables[key] {
                return existing
            }
            tables[key] = table
            return table
        }
    }

    private struct Builder {
        let definitions: [String: JSONSchema]
        /// The node of each definition, built once. A definition that refers to itself, directly
        /// or through others, gets its own node back while it is being filled (a cycle).
        var nodesByDefinition: [String: Node] = [:]
        /// Definitions with no atomic value anywhere below them.
        var empty: Set<String> = []

        init(definitions: [String: JSONSchema]) {
            self.definitions = definitions
        }

        /// The node for `schema`, or `nil` when no atomic value is at or below it.
        mutating func node(for schema: JSONSchema) throws -> Node? {
            if let ref = schema.ref {
                return try definitionNode(Self.definitionName(ref))
            }
            return try inlineNode(for: schema, name: nil)
        }

        private mutating func definitionNode(_ name: String) throws -> Node? {
            if empty.contains(name) { return nil }
            if let node = nodesByDefinition[name] { return node }
            guard let definition = definitions[name] else { return nil }
            if definition.xStateTree?.atomic == true {
                return try inlineNode(for: definition, name: name)
            }
            // `Optional<T>` that isn't atomic: the value is a `T` or null, so follow `T`.
            if definition.properties == nil, definition.additionalProperties == nil, definition.items == nil,
               definition.xStateTree?.optional == true, let inner = definition.xStateTree?.innerType {
                return try definitionNode(inner)
            }
            let node = Node(leafPaths: nil)
            nodesByDefinition[name] = node
            try fill(node, from: definition)
            // A node on a cycle stays, even if empty: the cycle already points at it.
            if node.isEmpty && !isOnCycle(node) {
                nodesByDefinition[name] = nil
                empty.insert(name)
                return nil
            }
            return node
        }

        private mutating func inlineNode(for schema: JSONSchema, name: String?) throws -> Node? {
            if schema.xStateTree?.atomic == true {
                let leafPaths = schema.xStateTree?.leafOrder ?? []
                try check(leafPaths, of: schema, named: name ?? "inline")
                return Node(leafPaths: leafPaths)
            }
            let node = Node(leafPaths: nil)
            try fill(node, from: schema)
            return node.isEmpty ? nil : node
        }

        private mutating func fill(_ node: Node, from schema: JSONSchema) throws {
            for (name, property) in schema.properties ?? [:] {
                if let child = try self.node(for: property) {
                    node.children[name] = child
                }
            }
            if let element = schema.additionalProperties ?? schema.items {
                node.wildcard = try self.node(for: element.value)
            }
        }

        /// Whether `node` can reach itself (it belongs to a recursive definition).
        private func isOnCycle(_ node: Node) -> Bool {
            var stack = Array(node.children.values) + (node.wildcard.map { [$0] } ?? [])
            var seen: Set<ObjectIdentifier> = []
            while let next = stack.popLast() {
                if next === node { return true }
                guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
                stack.append(contentsOf: next.children.values)
                if let wildcard = next.wildcard { stack.append(wildcard) }
            }
            return false
        }

        /// The declared leaves must be exactly the schema's leaves (every path ending at a scalar).
        private func check(_ declared: [[String]], of schema: JSONSchema, named name: String) throws {
            var described = schema
            // `Optional<T>`: the properties are on `T`'s definition.
            if schema.properties == nil, let inner = schema.xStateTree?.innerType, let definition = definitions[inner] {
                described = definition
            }
            let actual = Set(leaves(of: described, visiting: []))
            let declaredSet = Set(declared)
            let missing = actual.subtracting(declaredSet).sorted(by: Self.pathLess)
            let extra = declaredSet.subtracting(actual).sorted(by: Self.pathLess)
            if !missing.isEmpty || !extra.isEmpty || declared.count != declaredSet.count {
                throw BuildError(typeName: name, missing: missing, extra: extra)
            }
        }

        /// The leaf paths of `schema`'s properties; a collection contributes `name.*`, which no
        /// declaration can match, so a collection inside an atomic value fails the check.
        private func leaves(of schema: JSONSchema, visiting: Set<String>) -> [[String]] {
            var schema = schema
            var visiting = visiting
            if let ref = schema.ref {
                let name = Self.definitionName(ref)
                guard !visiting.contains(name), let definition = definitions[name] else { return [] }
                visiting.insert(name)
                schema = definition
            }
            if schema.items != nil || schema.additionalProperties != nil {
                return [["*"]]
            }
            guard let properties = schema.properties, !properties.isEmpty else {
                return []
            }
            var result: [[String]] = []
            for (name, property) in properties {
                let below = leaves(of: property, visiting: visiting)
                if below.isEmpty {
                    result.append([name])
                } else {
                    result.append(contentsOf: below.map { [name] + $0 })
                }
            }
            return result
        }

        private static func definitionName(_ ref: String) -> String {
            if let range = ref.range(of: "#/defs/") {
                return String(ref[range.upperBound...])
            }
            return ref
        }

        private static func pathLess(_ a: [String], _ b: [String]) -> Bool {
            a.joined(separator: ".") < b.joined(separator: ".")
        }
    }
}
