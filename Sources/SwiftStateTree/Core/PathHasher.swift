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
    /// hasher whose trie produced it.
    package let identity = PathHasherIdentity()

    /// The trie's root, to split a path one component at a time while a diff walks down the
    /// state (`Cursor`).
    package var rootCursor: Cursor {
        Cursor(node: root, dynamicKeys: [], rowSlot: nil, owner: identity)
    }
    
    public init(pathHashes: [String: UInt32]) {
        self.pathToHash = pathHashes
        self.hashToPath = Dictionary(uniqueKeysWithValues: pathHashes.map { ($1, $0) })
        self.sortedHashes = Array(Set(pathHashes.values)).sorted()
        self.indexOfHash = Dictionary(uniqueKeysWithValues: sortedHashes.enumerated().map { ($1, $0) })
        self.root = PathTrieNode()
        
        for (pattern, hash) in pathHashes {
            insert(pattern: pattern, hash: hash)
        }
    }
    
    private func insert(pattern: String, hash: UInt32) {
        let components = pattern.split(separator: ".").map(String.init)
        var currentNode = root
        
        for component in components {
            if component == "*" {
                if currentNode.wildcard == nil {
                    currentNode.wildcard = PathTrieNode()
                }
                currentNode = currentNode.wildcard!
            } else {
                if currentNode.children[component] == nil {
                    currentNode.children[component] = PathTrieNode()
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
}



/// The identity of a `PathHasher` (shared by its copies).
package final class PathHasherIdentity: Sendable {
    package init() {}
}

/// A path's split as `PathHasher.splitReportingMatch` gives it for a path inside the schema, with
/// the hasher it belongs to.
package struct PatchSplit: Sendable {
    package let pathHash: UInt32
    package let dynamicKeys: [String]
    /// The slot of the row the patch lies in, when that row is in a slotted table (a root node
    /// map on the typed diff): the row itself for its set or delete, the row holding the value
    /// otherwise. With one dynamic key the patch is the row or one of its leaves.
    package let rowSlot: Int32?
    fileprivate let owner: PathHasherIdentity

    /// This split in the row at `slot`.
    package func inRow(_ slot: Int32) -> PatchSplit {
        PatchSplit(pathHash: pathHash, dynamicKeys: dynamicKeys, rowSlot: slot, owner: owner)
    }

    /// Whether `hasher`'s own split of the same path is this one.
    package func belongs(to hasher: PathHasher) -> Bool {
        owner === hasher.identity
    }
}

extension PathHasher {
    /// A position in the trie after some leading components of a path: the same walk as
    /// `splitReportingMatch`, taken one component at a time. A walk that leaves the trie has no
    /// cursor, and a position without a hash has no split; such a path is split by the hasher,
    /// which applies its fallback.
    package struct Cursor: Sendable {
        fileprivate let node: PathTrieNode
        package let dynamicKeys: [String]
        /// The slot of the row this position is at or below (`PatchSplit.rowSlot`).
        package let rowSlot: Int32?
        fileprivate let owner: PathHasherIdentity

        /// This position, in the row at `slot`: every split from here down carries the slot.
        package func inRow(_ slot: Int32) -> Cursor {
            Cursor(node: node, dynamicKeys: dynamicKeys, rowSlot: slot, owner: owner)
        }

        /// The position after `component` (as the path spells it, escaped): a literal child
        /// first, then the wildcard, which takes the component as a dynamic key.
        package func descending(_ component: String) -> Cursor? {
            if let child = node.children[component] {
                return Cursor(node: child, dynamicKeys: dynamicKeys, rowSlot: rowSlot, owner: owner)
            }
            if let wildcard = node.wildcard {
                return Cursor(node: wildcard, dynamicKeys: dynamicKeys + [component], rowSlot: rowSlot, owner: owner)
            }
            return nil
        }

        /// The split of the path that ends here.
        package var split: PatchSplit? {
            node.hash.map { PatchSplit(pathHash: $0, dynamicKeys: dynamicKeys, rowSlot: rowSlot, owner: owner) }
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
