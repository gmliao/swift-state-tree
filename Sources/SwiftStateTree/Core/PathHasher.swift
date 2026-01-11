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
    private let pathToHash: [String: UInt32]
    
    /// Reverse mapping for debugging/validation
    private let hashToPath: [UInt32: String]
    
    public init(pathHashes: [String: UInt32]) {
        self.pathToHash = pathHashes
        self.hashToPath = Dictionary(uniqueKeysWithValues: pathHashes.map { ($1, $0) })
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
        // Convert JSON Pointer to normalized pattern
        let (pattern, dynamicKey) = normalizePath(path)
        
        if let hash = pathToHash[pattern] {
            return (hash, dynamicKey)
        }
        
        // Fallback: compute hash on-the-fly if not in table
        // This shouldn't happen in production if schema is complete
        let hash = DeterministicHash.fnv1a32(pattern)
        return (hash, dynamicKey)
    }
    
    /// Get the original path pattern for a hash (for debugging).
    public func getPath(for hash: UInt32) -> String? {
        hashToPath[hash]
    }
    
    // MARK: - Path Normalization
    
    /// Normalize JSON Pointer path to pattern with wildcards.
    ///
    /// Strategy: Replace ALL intermediate path segments with wildcards,
    /// keeping only the first and last segments as static.
    ///
    /// Examples:
    /// - `/players/42/position` → ("players.*.position", "42")
    /// - `/gameState/round` → ("gameState.round", nil)
    /// - `/players/42/inventory/0/itemId` → ("players.*.inventory.*.itemId", "42")
    ///
    /// Note: Only extracts first dynamic segment as the key.
    /// Multi-level dynamic paths preserve structure but only return first key.
    private func normalizePath(_ jsonPointer: String) -> (pattern: String, dynamicKey: String?) {
        // Remove leading slash and split
        let components = jsonPointer.dropFirst().split(separator: "/").map(String.init)
        
        guard components.count > 1 else {
            // Simple path with no dynamic parts
            return (components.joined(separator: "."), nil)
        }
        
        // Strategy: First and last are static, middle segments are wildcards
        var patternComponents: [String] = []
        var dynamicKey: String? = nil
        
        for (index, component) in components.enumerated() {
            if index == 0 || index == components.count - 1 {
                // Keep first and last as static
                patternComponents.append(component)
            } else {
                // Middle segments become wildcards
                patternComponents.append("*")
                // Capture first dynamic segment as the key
                if dynamicKey == nil {
                    dynamicKey = component
                }
            }
        }
        
        let pattern = patternComponents.joined(separator: ".")
        return (pattern, dynamicKey)
    }
}

