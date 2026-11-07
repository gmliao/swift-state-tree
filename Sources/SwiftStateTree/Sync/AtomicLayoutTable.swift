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

    /// One schema position on the way to an atomic value.
    package final class Node: Sendable {
        let children: [String: Node]
        let wildcard: Node?
        /// Set when the value at this position is atomic.
        package let leafPaths: [[String]]?

        init(children: [String: Node], wildcard: Node?, leafPaths: [[String]]?) {
            self.children = children
            self.wildcard = wildcard
            self.leafPaths = leafPaths
        }

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
        let root = try builder.node(for: rootSchema, path: [])
        return AtomicLayoutTable(root: root, patterns: builder.patterns)
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
        var patterns: [String: [[String]]] = [:]
        /// Definitions on the current branch, so a recursive type ends the walk.
        var visiting: Set<String> = []

        init(definitions: [String: JSONSchema]) {
            self.definitions = definitions
        }

        /// The node for `schema` at `path`, or `nil` when no atomic value is below it.
        mutating func node(for schema: JSONSchema, path: [String]) throws -> Node? {
            var schema = schema
            var refName: String?
            if let ref = schema.ref {
                let name = Self.definitionName(ref)
                guard !visiting.contains(name), let definition = definitions[name] else {
                    return nil
                }
                refName = name
                schema = definition
            }
            if let refName { visiting.insert(refName) }
            defer { if let refName { visiting.remove(refName) } }

            if schema.xStateTree?.atomic == true {
                let leafPaths = schema.xStateTree?.leafOrder ?? []
                try check(leafPaths, of: schema, named: refName ?? path.joined(separator: "."))
                patterns[path.joined(separator: ".")] = leafPaths
                return Node(children: [:], wildcard: nil, leafPaths: leafPaths)
            }

            var children: [String: Node] = [:]
            for (name, property) in schema.properties ?? [:] {
                if let child = try node(for: property, path: path + [name]) {
                    children[name] = child
                }
            }
            var wildcard: Node?
            if let element = schema.additionalProperties ?? schema.items {
                wildcard = try node(for: element.value, path: path + ["*"])
            }
            if children.isEmpty && wildcard == nil {
                return nil
            }
            return Node(children: children, wildcard: wildcard, leafPaths: nil)
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
