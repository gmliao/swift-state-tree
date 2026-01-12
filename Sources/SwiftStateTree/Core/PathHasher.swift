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
    
    public init(pathHashes: [String: UInt32]) {
        self.pathToHash = pathHashes
        self.hashToPath = Dictionary(uniqueKeysWithValues: pathHashes.map { ($1, $0) })
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
    
    /// Split a JSON Pointer path into (pathHash, dynamicKey).
    ///
    /// Examples:
    /// - `/players/42/position` → (hash("players.*.position"), "42")
    /// - `/gameState/round` → (hash("gameState.round"), nil)
    ///
    /// - Parameter path: JSON Pointer path (e.g., "/players/42/hp")
    /// - Returns: Tuple of (pathHash, dynamicKey or nil)
    public func split(_ path: String) -> (pathHash: UInt32, dynamicKey: String?) {
        // Remove leading slash and split
        let components = path.dropFirst().split(separator: "/").map(String.init)
        
        // Traverse Trie
        var currentNode = root
        var dynamicKey: String? = nil
        
        for component in components {
            if let child = currentNode.children[component] {
                currentNode = child
            } else if let wildcard = currentNode.wildcard {
                currentNode = wildcard
                // Capture FIRST dynamic key
                if dynamicKey == nil {
                    dynamicKey = component
                }
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
                return (hash, fallbackKey)
            }
        }
        
        if let hash = currentNode.hash {
            return (hash, dynamicKey)
        }
        
        // Path ended but no hash at this node (intermediate node)
        // e.g. path is "/players" but only "/players.*" has hash? 
        // Actually intermediate nodes (like maps) usually do have hashes.
        // Fallback
        let (fallbackPattern, fallbackKey) = normalizePathFallback(path)
        let hash = DeterministicHash.fnv1a32(fallbackPattern)
        return (hash, fallbackKey)
    }
    
    /// Get the original path pattern for a hash (for debugging).
    public func getPath(for hash: UInt32) -> String? {
        hashToPath[hash]
    }
    
    // MARK: - Legacy Normalization (Fallback)
    
    private func normalizePathFallback(_ jsonPointer: String) -> (pattern: String, dynamicKey: String?) {
        // Remove leading slash and split
        let components = jsonPointer.dropFirst().split(separator: "/").map(String.init)
        
        guard components.count > 1 else {
            return (components.joined(separator: "."), nil)
        }
        
        var patternComponents: [String] = []
        var dynamicKey: String? = nil
        
        for (index, component) in components.enumerated() {
            if index == 0 || index == components.count - 1 {
                patternComponents.append(component)
            } else {
                patternComponents.append("*")
                if dynamicKey == nil {
                    dynamicKey = component
                }
            }
        }
        
        let pattern = patternComponents.joined(separator: ".")
        return (pattern, dynamicKey)
    }
}

fileprivate final class PathTrieNode: @unchecked Sendable {
    var children: [String: PathTrieNode] = [:]
    var wildcard: PathTrieNode?
    var hash: UInt32?
    var pattern: String?
}


