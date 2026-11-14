import Foundation

/// Path hashing utility for compressing state update paths.
///
/// Converts JSON Pointer paths like `/players/42/position` into:
/// - Path hash: `DeterministicHash.fnv1a32("players.*.position")` → UInt32
/// - Dynamic key: `42` (preserved as-is, whether string or number)
///
/// **Design Philosophy:**
/// - Static path patterns are hashed for compression
/// - Dynamic keys (map keys, array indices) are preserved as-is
/// - Developers should use Int32/Int for map keys to minimize size
///
/// This significantly reduces bandwidth by replacing long path strings with 4-byte hashes.
public struct PathHasher: Sendable {
    
    /// Maps normalized path patterns to their hashes
    /// Example: "players.*.position" → 0x12345678

    /// Maps normalized path patterns to their hashes
    /// Example: "players.*.position" → 0x12345678
    private let pathToHash: [String: UInt32]
    
    /// Reverse mapping for debugging/validation
    private let hashToPath: [UInt32: String]
    
    /// Root of the path pattern trie
    private let root: PathTrieNode

    /// The land's path hashes, de-duplicated and sorted ascending: a pattern's path index is its
    /// hash's position here (the `pathIndex` wire form). Server and client derive it from the
    /// same schema `pathHashes`.
    public let sortedHashes: [UInt32]

    /// Hash → path index (position in `sortedHashes`).
    private let indexOfHash: [UInt32: Int]

    /// Tells this hasher (and its copies) from every other one: a split is only valid for the
    /// hasher whose trie produced it. It also holds the trie's templates, from which a split
    /// rebuilds its path (`PatchSplit.rebuiltPath()`).
    package let identity: PathHasherIdentity

    /// The trie's root, to split a path one component at a time while a diff walks down the
    /// state (`Cursor`).
    package var rootCursor: Cursor {
        Cursor(node: root, dynamicKeys: [], row: nil, owner: identity, isLossless: true)
    }

    public init(pathHashes: [String: UInt32]) {
        self.pathToHash = pathHashes
        self.hashToPath = Dictionary(uniqueKeysWithValues: pathHashes.map { ($1, $0) })
        self.sortedHashes = Array(Set(pathHashes.values)).sorted()
        self.indexOfHash = Dictionary(uniqueKeysWithValues: sortedHashes.enumerated().map { ($1, $0) })
        let root = PathTrieNode(index: 0, label: nil)
        self.root = root
        // The trie's nodes in creation order, each with its parent and its label (nil for the
        // root and a wildcard): a node's template, kept flat in the identity (no node refers to
        // the identity).
        var entries = [PathHasherIdentity.Entry(parent: -1, label: nil)]
        for (pattern, hash) in pathHashes.sorted(by: { $0.key < $1.key }) {
            Self.insert(pattern: pattern, hash: hash, root: root, entries: &entries)
        }
        self.identity = PathHasherIdentity(entries: entries)
    }

    private static func insert(
        pattern: String, hash: UInt32, root: PathTrieNode, entries: inout [PathHasherIdentity.Entry]
    ) {
        let components = pattern.split(separator: ".").map(String.init)
        var currentNode = root

        for component in components {
            if component == "*" {
                if currentNode.wildcard == nil {
                    currentNode.wildcard = PathTrieNode(index: Int32(entries.count), label: nil)
                    entries.append(PathHasherIdentity.Entry(parent: currentNode.index, label: nil))
                }
                currentNode = currentNode.wildcard!
            } else {
                if currentNode.children[component] == nil {
                    currentNode.children[component] = PathTrieNode(index: Int32(entries.count), label: component)
                    entries.append(PathHasherIdentity.Entry(parent: currentNode.index, label: component))
                }
                currentNode = currentNode.children[component]!
            }
        }
        currentNode.hash = hash
        currentNode.pattern = pattern
    }
    
    /// The schema patterns and their hashes this hasher was built from.
    public var pathHashes: [String: UInt32] { pathToHash }

    /// The path index of a schema pattern's hash; nil for a hash outside the schema.
    public func pathIndex(of hash: UInt32) -> Int? {
        indexOfHash[hash]
    }

    /// The hash at a path index; nil when the index is out of range.
    public func hash(atPathIndex index: Int) -> UInt32? {
        sortedHashes.indices.contains(index) ? sortedHashes[index] : nil
    }

    /// Split a JSON Pointer path into (pathHash, dynamicKeys).
    ///
    /// Examples:
    /// - `/players/42/position` → (hash("players.*.position"), ["42"])
    /// - `/gameState/round` → (hash("gameState.round"), nil)
    /// - `/players/42/inventory/7/itemId` → (hash("players.*.inventory.*.itemId"), ["42", "7"])
    ///
    /// - Parameter path: JSON Pointer path (e.g., "/players/42/hp")
    /// - Returns: Tuple of (pathHash, dynamicKeys)
    public func split(_ path: String) -> (pathHash: UInt32, dynamicKeys: [String]) {
        let (pathHash, dynamicKeys, _) = splitReportingMatch(path)
        return (pathHash, dynamicKeys)
    }

    /// `split(path)`, and whether the path matched a schema pattern (`inSchema`). When it
    /// didn't, the hash is the fallback heuristic's, which may even equal a schema hash.
    public func splitReportingMatch(_ path: String) -> (pathHash: UInt32, dynamicKeys: [String], inSchema: Bool) {
        let components = Self.components(of: path)
        
        // Traverse Trie
        var currentNode = root
        var dynamicKeys: [String] = []
        
        for component in components {
            if let child = currentNode.children[component] {
                currentNode = child
            } else if let wildcard = currentNode.wildcard {
                currentNode = wildcard
                // Capture ALL dynamic keys in traversal order
                dynamicKeys.append(component)
            } else {
                // No match found in known patterns
                // Fallback: Try the legacy heuristic (though it's likely wrong for deep paths)
                // or just hash the raw path?
                // Ideally we should return a "not found" or log, but here we must return something.
                // Logically, if the schema is complete, this shouldn't happen for valid paths.
                // If we fallback to heuristic normalization, we might produce a hash that isn't in schema
                // (which is what was happening before).
                let (fallbackPattern, fallbackKey) = normalizePathFallback(path)
                let hash = DeterministicHash.fnv1a32(fallbackPattern)
                return (hash, fallbackKey, false)
            }
        }
        
        if let hash = currentNode.hash {
            return (hash, dynamicKeys, true)
        }
        
        // Path ended but no hash at this node (intermediate node)
        // e.g. path is "/players" but only "/players.*" has hash? 
        // Actually intermediate nodes (like maps) usually do have hashes.
        // Fallback
        let (fallbackPattern, fallbackKey) = normalizePathFallback(path)
        let hash = DeterministicHash.fnv1a32(fallbackPattern)
        return (hash, fallbackKey, false)
    }
    
    /// The components of a JSON Pointer, empty ones included: `/m/` is the entry of `m` under
    /// the key `""`, and `/m//v` its field `v`. The root pointer (`""` or `/`) has none.
    static func components(of path: String) -> [String] {
        let body = path.hasPrefix("/") ? path.dropFirst() : Substring(path)
        if body.isEmpty { return [] }
        return body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    /// Get the original path pattern for a hash (for debugging).
    public func getPath(for hash: UInt32) -> String? {
        hashToPath[hash]
    }
    
    // MARK: - Legacy Normalization (Fallback)
    
    private func normalizePathFallback(_ jsonPointer: String) -> (pattern: String, dynamicKeys: [String]) {
        let components = Self.components(of: jsonPointer)
        
        guard components.count > 1 else {
            return (components.joined(separator: "."), [])
        }
        
        var patternComponents: [String] = []
        var dynamicKeys: [String] = []
        
        for (index, component) in components.enumerated() {
            if index == 0 || index == components.count - 1 {
                patternComponents.append(component)
            } else {
                patternComponents.append("*")
                dynamicKeys.append(component)
            }
        }
        
        let pattern = patternComponents.joined(separator: ".")
        return (pattern, dynamicKeys)
    }
}

/// Internal Trie node for path pattern matching.
///
/// **Thread Safety:**
/// - This class uses `@unchecked Sendable` because Swift structs cannot have recursive stored properties.
/// - The Trie structure is built during `PathHasher.init()` and is **immutable after initialization**.
/// - All read operations (`split` method) only traverse the tree without modification.
/// - This design ensures thread safety: multiple threads can safely read from the same `PathHasher` instance concurrently.
fileprivate final class PathTrieNode: @unchecked Sendable {
    var children: [String: PathTrieNode] = [:]
    var wildcard: PathTrieNode?
    var hash: UInt32?
    var pattern: String?
    /// This node's position in its identity's templates (`PathHasherIdentity.entries`).
    let index: Int32
    /// The literal label as the pattern spells it; nil for the root and a wildcard.
    let label: String?
    /// Whether `label` is ASCII: a component `String`-equal to it then has its bytes exactly
    /// when it has its length (a canonically equivalent spelling with a non-ASCII scalar, such
    /// as U+212A for `K`, is longer).
    let labelIsASCII: Bool

    init(index: Int32, label: String?) {
        self.index = index
        self.label = label
        self.labelIsASCII = label?.utf8.allSatisfy { $0 < 0x80 } ?? true
    }

    /// Whether `component`, which matched this node's label as a `String`, has its bytes.
    func spellsLabel(_ component: String) -> Bool {
        guard let label else { return true }
        return labelIsASCII
            ? component.utf8.count == label.utf8.count
            : component.utf8.elementsEqual(label.utf8)
    }
}

/// The identity of a `PathHasher` (shared by its copies), and the templates its splits rebuild
/// their paths from: one entry per trie node, its parent and its label, built once with the
/// trie and immutable after. Memory is one entry per node; a rebuild walks the node's depth.
/// The entries are values: nothing in them refers to the identity, a node or a cursor.
package final class PathHasherIdentity: Sendable {
    fileprivate struct Entry: Sendable {
        let parent: Int32
        /// The literal label as the pattern spells it; nil for the root and a wildcard (a key).
        let label: String?
    }

    fileprivate let entries: [Entry]

    fileprivate init(entries: [Entry]) {
        self.entries = entries
    }

    /// The path of the node at `index` with `keys` in its wildcards, in order: each literal as
    /// its label spells it, each key as given, `/`-joined. The keys are escaped already.
    fileprivate func path(atNode index: Int32, keys: [String]) -> String {
        var parts: [String] = []
        var length = 0
        var node = index
        var key = keys.count
        while node > 0 {
            let entry = entries[Int(node)]
            let part: String
            if let label = entry.label {
                part = label
            } else {
                key -= 1
                part = keys[key]
            }
            parts.append(part)
            length += part.utf8.count + 1
            node = entry.parent
        }
        assert(key == 0, "a split's keys must fill its pattern's wildcards")
        var path = ""
        path.reserveCapacity(length)
        for part in parts.reversed() {
            path += "/"
            path += part
        }
        return path
    }
}

/// A path's split as `PathHasher.splitReportingMatch` gives it for a path inside the schema, with
/// the hasher it belongs to.
package struct PatchSplit: Sendable {
    package let pathHash: UInt32
    package let dynamicKeys: [String]
    /// The row the patch lies in, when that row is in a slotted table (a root node map on the
    /// typed diff): the row itself for its set or delete, the row holding the value otherwise.
    /// With one dynamic key the patch is the row (`pathHash == row.table`) or one of its leaves.
    package let row: PatchRow?
    fileprivate let owner: PathHasherIdentity
    /// The trie node of `pathHash`'s pattern (`PathHasherIdentity.entries`).
    fileprivate let node: Int32

    /// The slot of the row the patch lies in (`row`).
    package var rowSlot: Int32? { row?.slot }

    /// This split, of a row's own path, as the row at `slot`. `generation` is given for a
    /// create.
    package func asRow(_ slot: Int32, generation: UInt32? = nil) -> PatchSplit {
        PatchSplit(
            pathHash: pathHash, dynamicKeys: dynamicKeys,
            row: PatchRow(table: pathHash, slot: slot, generation: generation), owner: owner, node: node
        )
    }

    /// Whether `hasher`'s own split of the same path is this one.
    package func belongs(to hasher: PathHasher) -> Bool {
        owner === hasher.identity
    }

    /// Whether `other` is a split of the same hasher.
    package func hasOwner(of other: PatchSplit) -> Bool {
        owner === other.owner
    }

    /// The path this split names: the pattern's labels as the trie spells them, with the keys
    /// in its wildcards. The emit's own path, byte for byte, when every literal the emit wrote
    /// had its label's bytes (`Cursor.isLossless`).
    package func rebuiltPath() -> String {
        owner.path(atNode: node, keys: dynamicKeys)
    }
}

/// A row of a slotted table, as a patch's split names it.
package struct PatchRow: Sendable, Equatable {
    /// The pattern hash of the table's rows (`monsters.*`).
    package let table: UInt32
    package let slot: Int32
    /// The slot's generation, on the patch that creates the row.
    package let generation: UInt32?
}

extension PathHasher {
    /// A position in the trie after some leading components of a path: the same walk as
    /// `splitReportingMatch`, taken one component at a time. A walk that leaves the trie has no
    /// cursor, and a position without a hash has no split; such a path is split by the hasher,
    /// which applies its fallback.
    package struct Cursor: Sendable {
        fileprivate let node: PathTrieNode
        package let dynamicKeys: [String]
        /// The row this position is at or below (`PatchSplit.row`).
        package let row: PatchRow?
        fileprivate let owner: PathHasherIdentity
        /// Whether every literal component so far had its trie label's bytes, not only a
        /// `String`-equal spelling: then `rebuiltPath` is the walked path byte for byte.
        package let isLossless: Bool

        /// This position, a row's own, as the row at `slot`: every split from here down carries
        /// the row. A position without a hash is no table's row, and stays as it is.
        package func asRow(_ slot: Int32) -> Cursor {
            guard let table = node.hash else { return self }
            return Cursor(
                node: node, dynamicKeys: dynamicKeys, row: PatchRow(table: table, slot: slot, generation: nil),
                owner: owner, isLossless: isLossless
            )
        }

        /// The position after `component` (as the path spells it, escaped): a literal child
        /// first, then the wildcard, which takes the component as a dynamic key.
        package func descending(_ component: String) -> Cursor? {
            if let child = node.children[component] {
                return Cursor(
                    node: child, dynamicKeys: dynamicKeys, row: row, owner: owner,
                    isLossless: isLossless && child.spellsLabel(component)
                )
            }
            if let wildcard = node.wildcard {
                return Cursor(
                    node: wildcard, dynamicKeys: dynamicKeys + [component], row: row, owner: owner,
                    isLossless: isLossless
                )
            }
            return nil
        }

        /// The split of the path that ends here.
        package var split: PatchSplit? {
            node.hash.map { PatchSplit(pathHash: $0, dynamicKeys: dynamicKeys, row: row, owner: owner, node: node.index) }
        }

        /// The path walked to here, rebuilt from the templates: the walk's own bytes when
        /// `isLossless`. For a position without a hash (an intermediate node), where a walk-off
        /// below it needs the path as a string.
        package var rebuiltPath: String {
            owner.path(atNode: node.index, keys: dynamicKeys)
        }

        /// The split of `path`, which is `base` (the path that ends here) or lies under it.
        package func split(of path: String, under base: String) -> PatchSplit? {
            let rest = path.utf8.dropFirst(base.utf8.count)
            guard !rest.isEmpty else { return split }
            // `rest` starts with the "/" after `base`.
            var cursor = self
            for component in rest.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false) {
                guard let next = cursor.descending(String(decoding: component, as: UTF8.self)) else { return nil }
                cursor = next
            }
            return cursor.split
        }
    }
}
