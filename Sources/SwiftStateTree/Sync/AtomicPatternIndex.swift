import Foundation

/// The atomic table position (`AtomicLayoutTable.node(atPath:)`) of every schema pattern of a
/// `PathHasher`, resolved once, so an opcode encoder finds a patch's position from its split's
/// pattern hash instead of splitting and walking the path for every value.
///
/// A split inside the schema is the hasher's trie walk: each literal step consumed a component
/// equal to its label, each `*` step the next dynamic key. The string walk takes
/// `children[component] ?? wildcard` at each step, so a pattern's answer is the same for every
/// path that splits to it, except where a `*` step leaves a node with named children: there a
/// key equal to a child's name takes that child. Such a pattern keeps the string walk
/// (`.walkPath`); so does a split outside the schema, whose hash is the fallback heuristic's and
/// may equal a schema pattern's.
package struct AtomicPatternIndex: Sendable {
    /// A pattern's table position, or that it depends on the path's keys.
    package enum Resolution: Sendable {
        case node(AtomicLayoutTable.Node?)
        case walkPath
    }

    package let table: AtomicLayoutTable
    private let resolutions: [UInt32: Resolution]

    /// `hasher`'s patterns resolved in `table`. A hash names one pattern: `PathHasher.init`
    /// traps on a duplicate.
    package init(table: AtomicLayoutTable, hasher: PathHasher) {
        self.table = table
        self.resolutions = Dictionary(
            uniqueKeysWithValues: hasher.pathHashes.map { pattern, hash in (hash, Self.resolve(pattern, in: table)) }
        )
    }

    /// The position of the paths that split to `pattern` (path-hash form, `units.*.position`).
    package static func resolve(_ pattern: String, in table: AtomicLayoutTable) -> Resolution {
        guard var current = table.root else { return .node(nil) }
        // The trie's labels for the pattern (`PathHasher.insert`).
        for label in pattern.split(separator: ".") {
            if label == "*" {
                // The key decides between a named child and the wildcard.
                guard current.children.isEmpty else { return .walkPath }
                guard let next = current.wildcard else { return .node(nil) }
                current = next
            } else {
                guard let next = current.child(String(label)) else { return .node(nil) }
                current = next
            }
        }
        return .node(current)
    }

    /// The resolution of the pattern with hash `pathHash`, if it is one of the hasher's.
    package func resolution(ofPathHash pathHash: UInt32) -> Resolution? {
        resolutions[pathHash]
    }

    /// The table position of `path`, whose split (by the hasher this index was built from) has
    /// `pathHash` and `inSchema`: `table.node(atPath: path)`, without the walk when the pattern
    /// decides it. `path` is built only for the walk (#392).
    @inline(__always)
    package func node(pathHash: UInt32, inSchema: Bool, path: @autoclosure () -> String) -> AtomicLayoutTable.Node? {
        if inSchema, case .node(let node)? = resolutions[pathHash] {
            return node
        }
        return table.node(atPath: path())
    }

    /// `table.positional(value, atPath: path)` for a path with that split. `path` is built only
    /// for the walk and for an error (#392).
    @inline(__always)
    package func positional(
        _ value: SnapshotValue, pathHash: UInt32, inSchema: Bool, path: @autoclosure () -> String
    ) throws -> SnapshotValue {
        try table.positional(value, at: node(pathHash: pathHash, inSchema: inSchema, path: path()), path: path)
    }
}
