import Foundation

/// Same-parent field merge for opcode state updates: which patches can share one merged entry
/// (`[parentId, dynamicKey, op, fieldMask, v1, v2, …]`), and the field each mask bit names.
///
/// - **A field** is a schema pattern whose last component is a name (not `*`) and whose parent
///   (the pattern without that component) is a schema pattern too, so a root field has none.
/// - **Its bit** is its rank among the parent's named children (patterns `parent.<name>`),
///   sorted by name in byte order. Fields of rank `maxFields` or above aren't merged.
/// - **A mergeable field** is a leaf: a pattern with no longer pattern below it, or an atomic
///   pattern (an atomic value is one value on the wire). An object-level set isn't merged.
///
/// The decoder needs only the children by rank; leaves and atomic patterns matter to the encoder.
public struct FieldMergeTable: Sendable {
    /// A mergeable field's parent pattern hash and bit.
    public struct Field: Sendable, Equatable {
        public let parentHash: UInt32
        public let bit: Int
        /// The schema has patterns below it (an atomic value's leaves), so a patch to it can
        /// be the parent of another field's patch.
        public let hasPatternsBelow: Bool

        public init(parentHash: UInt32, bit: Int, hasPatternsBelow: Bool = false) {
            self.parentHash = parentHash
            self.bit = bit
            self.hasPatternsBelow = hasPatternsBelow
        }
    }

    /// The widest mask: a 32-bit unsigned integer, which every client reads exactly (a
    /// JavaScript number holds integers up to 2^53, and its bitwise operators are 32-bit).
    public static let maxFields = 32

    private let fieldOfHash: [UInt32: Field]
    private let childrenOfParent: [UInt32: [UInt32]]

    /// - Parameters:
    ///   - pathHashes: the land's schema patterns and their hashes.
    ///   - atomicPatterns: patterns of atomic values (`AtomicLayoutTable.patterns`' keys).
    public init(pathHashes: [String: UInt32], atomicPatterns: Set<String> = []) {
        var hasChildren: Set<String> = []
        var namedChildren: [String: [String]] = [:]
        for pattern in pathHashes.keys {
            let components = pattern.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count > 1 else { continue }
            let parent = components.dropLast().joined(separator: ".")
            hasChildren.insert(parent)
            // Every proper prefix has a pattern below it.
            for length in 1 ..< components.count - 1 {
                hasChildren.insert(components.prefix(length).joined(separator: "."))
            }
            let name = String(components[components.count - 1])
            if name != "*", pathHashes[parent] != nil {
                namedChildren[parent, default: []].append(name)
            }
        }
        var fieldOfHash: [UInt32: Field] = [:]
        var childrenOfParent: [UInt32: [UInt32]] = [:]
        for (parent, names) in namedChildren {
            guard let parentHash = pathHashes[parent] else { continue }
            let sorted = names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            let hashes = sorted.compactMap { pathHashes["\(parent).\($0)"] }
            childrenOfParent[parentHash] = Array(hashes.prefix(Self.maxFields))
            for (bit, name) in sorted.enumerated() where bit < Self.maxFields {
                let pattern = "\(parent).\(name)"
                let below = hasChildren.contains(pattern)
                guard let hash = pathHashes[pattern], !below || atomicPatterns.contains(pattern) else { continue }
                fieldOfHash[hash] = Field(parentHash: parentHash, bit: bit, hasPatternsBelow: below)
            }
        }
        self.fieldOfHash = fieldOfHash
        self.childrenOfParent = childrenOfParent
    }

    /// The mergeable field a pattern hash names; nil for any other pattern.
    public func field(ofHash hash: UInt32) -> Field? {
        fieldOfHash[hash]
    }

    /// The child pattern hash at `bit` under a parent; nil when there is none.
    public func childHash(parent: UInt32, bit: Int) -> UInt32? {
        guard let children = childrenOfParent[parent], children.indices.contains(bit) else { return nil }
        return children[bit]
    }
}
