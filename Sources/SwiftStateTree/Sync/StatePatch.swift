// Sources/SwiftStateTree/Sync/StatePatch.swift

import Foundation

/// Operation type for state patches.
///
/// Maps to JSON Patch operations (RFC 6902):
/// - `.set` -> "replace" or "add" (depending on path existence)
/// - `.delete` -> "remove"
/// - `.add` -> "add" (for array operations)
public enum PatchOperation: Equatable, Sendable, Codable {
    /// Set a value at the path (creates or updates)
    case set(SnapshotValue)
    /// Delete the value at the path
    case delete
    /// Add a value to an array at the path (future extension)
    case add(SnapshotValue)
    
    /// JSON Patch operation string (RFC 6902)
    var jsonPatchOp: String {
        switch self {
        case .set:
            return "replace" // or "add" depending on context
        case .delete:
            return "remove"
        case .add:
            return "add"
        }
    }
    
    /// Encode as JSON Patch format
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .set(let value):
            // For JSON Patch, we encode as an object with "op", "path", "value"
            // But since this is just the operation, we'll encode the value
            try container.encode(value)
        case .delete:
            // Delete operation doesn't need a value
            try container.encodeNil()
        case .add(let value):
            try container.encode(value)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .delete
        } else {
            let value = try container.decode(SnapshotValue.self)
            self = .set(value)
        }
    }
}

/// Represents a single change to the state tree at a specific path.
///
/// Paths use JSON Pointer format (RFC 6901), e.g., "/players/alice/hpCurrent"
/// Serializes to JSON Patch format (RFC 6902) for transport:
/// ```json
/// {
///   "op": "replace",
///   "path": "/players/alice/hpCurrent",
///   "value": 100
/// }
/// ```
public struct StatePatch: Equatable, Sendable, Codable {
    /// Where the patch is: a path string, a split whose path is rebuilt on demand, or both.
    private enum Location: Sendable {
        /// No split (the json encoding, the snapshot diff, a decoded patch).
        case path(String)
        /// A lossless split (`PathHasher.Cursor.isLossless`): `path` is rebuilt from it, and is
        /// the emit's own path byte for byte.
        case split(PatchSplit)
        /// A split whose path the templates can't rebuild byte for byte (a literal spelled
        /// differently from its trie label but `String`-equal to it): the path is kept as the
        /// emit spelled it, and the split still names the pattern, row slot and generation.
        case pathAndSplit(String, PatchSplit)
    }

    private let location: Location

    /// JSON Pointer path to the changed field. For a patch made from a lossless split, built
    /// from the split on each call: a reader that needs it more than once takes it once.
    public var path: String {
        switch location {
        case .path(let path), .pathAndSplit(let path, _):
            return path
        case .split(let split):
            #if DEBUG
            StatePatch.pathRebuilds?.record()
            #endif
            return split.rebuiltPath()
        }
    }

    /// Operation to perform at this path
    public let operation: PatchOperation

    /// The path's split (pattern hash and dynamic keys), when the diff that made the patch
    /// already knew it: an encoder with the same `PathHasher` takes it instead of splitting the
    /// path again. Not part of the patch's value: `==` and `Codable` ignore it, and a patch built
    /// from another one doesn't carry it.
    package var split: PatchSplit? {
        switch location {
        case .path: return nil
        case .split(let split), .pathAndSplit(_, let split): return split
        }
    }

    /// Whether the patch holds no path string (`path` is rebuilt from its split on each call).
    package var isSplitOnly: Bool {
        if case .split = location { return true }
        return false
    }

    public init(path: String, operation: PatchOperation) {
        self.location = .path(path)
        self.operation = operation
    }

    /// A patch at `path` with the split the diff already knew, kept beside the string.
    package init(path: String, operation: PatchOperation, split: PatchSplit?) {
        self.location = split.map { .pathAndSplit(path, $0) } ?? .path(path)
        self.operation = operation
    }

    /// A patch at a lossless split's path (`PathHasher.Cursor.isLossless`), which isn't built
    /// until a reader asks for it.
    package init(split: PatchSplit, operation: PatchOperation) {
        self.location = .split(split)
        self.operation = operation
    }

    /// This patch with `split` in place of its split (a row create's generation), in the same
    /// form, without reading its path.
    package func retagged(_ split: PatchSplit) -> StatePatch {
        switch location {
        case .split:
            return StatePatch(split: split, operation: operation)
        case .path(let path), .pathAndSplit(let path, _):
            return StatePatch(path: path, operation: operation, split: split)
        }
    }

    /// Same path (`String` equality) and same operation. Two split-only patches of one hasher
    /// compare their splits: the same pattern and `String`-equal keys are exactly a
    /// `String`-equal path, since both spell the pattern's literals the same and `/` separates
    /// the components in both.
    public static func == (lhs: StatePatch, rhs: StatePatch) -> Bool {
        guard lhs.operation == rhs.operation else { return false }
        if case .split(let a) = lhs.location, case .split(let b) = rhs.location, a.hasOwner(of: b) {
            return a.pathHash == b.pathHash && a.dynamicKeys == b.dynamicKeys
        }
        return lhs.path == rhs.path
    }

    #if DEBUG
    /// Counts `path` rebuilds of split-only patches, in DEBUG builds, for the task that sets it
    /// (`$pathRebuilds.withValue`): a test that a reader on the success path takes the split
    /// and builds no path. `debugRebuiltPath` doesn't count.
    @TaskLocal package static var pathRebuilds: PathRebuildCounter?

    /// `path`, without counting a rebuild (`pathRebuilds`): for DEBUG checks that read the path
    /// beside the production readers.
    package var debugRebuiltPath: String {
        switch location {
        case .path(let path), .pathAndSplit(let path, _): return path
        case .split(let split): return split.rebuiltPath()
        }
    }
    #endif
    
    /// Encode as JSON Patch format (RFC 6902)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        
        switch operation {
        case .set(let value):
            try container.encode("replace", forKey: .op)
            try container.encode(value, forKey: .value)
        case .delete:
            try container.encode("remove", forKey: .op)
            // "remove" operation doesn't include "value"
        case .add(let value):
            try container.encode("add", forKey: .op)
            try container.encode(value, forKey: .value)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = .path(try container.decode(String.self, forKey: .path))
        let op = try container.decode(String.self, forKey: .op)
        
        switch op {
        case "replace", "add":
            let value = try container.decode(SnapshotValue.self, forKey: .value)
            operation = op == "add" ? .add(value) : .set(value)
        case "remove":
            operation = .delete
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op,
                in: container,
                debugDescription: "Unknown JSON Patch operation: \(op)"
            )
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case op
        case path
        case value
    }
}

#if DEBUG
/// The `path` rebuilds of split-only patches seen by the task that set
/// `StatePatch.pathRebuilds` (DEBUG builds only).
package final class PathRebuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    package init() {}

    package var count: Int { lock.withLock { total } }

    func record() { lock.withLock { total += 1 } }
}
#endif
