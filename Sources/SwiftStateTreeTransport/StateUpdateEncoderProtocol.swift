import Foundation
import SwiftStateTree

/// Supported encodings for state update payloads.
public enum StateUpdateEncoding: String, Sendable {
    case jsonObject
    case opcodeJsonArray
    case opcodeJsonArrayLegacy
    /// Opcode array format serialized as MessagePack binary.
    /// Structure matches `opcodeJsonArray`, but uses MessagePack instead of JSON text.
    case opcodeMessagePack
}

/// Opcode for state update types.
public enum StateUpdateOpcode: Int, Sendable {
    case noChange = 0
    case firstSync = 1
    case diff = 2
}

/// Scope for dynamic key tables when encoding opcode state updates.
public enum StateUpdateKeyScope: Sendable {
    case broadcast
    case perPlayer
}

/// Opcode for state patch operations.
public enum StatePatchOpcode: Int, Sendable {
    case set = 1
    case remove = 2
    case add = 3
}

/// Encodes state updates for transport.
public protocol StateUpdateEncoder: Sendable {
    var encoding: StateUpdateEncoding { get }
    func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data
    /// Encode with optional playerSlot for compression (uses playerSlot if provided, otherwise falls back to playerID)
    func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data
}

/// An encoder that says whether it keeps dynamic key tables (`[slot, key]` definitions and bare
/// slots). Without tables a key scope reset only costs frames, so the adapter skips the resets it
/// would request for late joiners (#90). An encoder that doesn't conform is assumed to keep them.
package protocol DynamicKeyTableReporting {
    var keepsDynamicKeyTables: Bool { get }
}

/// Encoders that support broadcast/per-player scoped dynamic key tables.
public protocol StateUpdateEncoderWithScope: StateUpdateEncoder {
    func encode(
        update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope
    ) throws -> Data
}

/// A state update the opcode encoders can't send.
public enum StateUpdateEncodingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// With the path index on: a patch path that matches no schema pattern has no index, and a
    /// decoder must not guess one, so the patch can't be sent (#287 is the known class).
    case pathNotInSchema(String)

    public var description: String {
        switch self {
        case .pathNotInSchema(let path): return "path not in the schema (no path index): \(path)"
        }
    }
}

/// With `pathIndex` on: patches dropped from a state update because their path has no schema
/// pattern. The encoder throws for such a patch and notes its pattern (`noteUnmapped`, which
/// runs `onFirstPattern` once per distinct pattern, keyed by its fallback hash, for a log line).
/// The adapter's unencodable-patch salvage then sends the update without it and counts it here
/// (`recordDroppedPatch`), once per dropped patch.
public final class UnmappedPathCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var seen: Set<UInt32> = []
    private let onFirstPattern: (@Sendable (String) -> Void)?

    public init(onFirstPattern: (@Sendable (String) -> Void)? = nil) {
        self.onFirstPattern = onFirstPattern
    }

    /// The number of dropped patches recorded.
    public var droppedPatches: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// An encoder met a path outside the schema; logs its pattern the first time.
    func noteUnmapped(path: String, hash: UInt32) {
        lock.lock()
        let first = seen.insert(hash).inserted
        lock.unlock()
        if first { onFirstPattern?(path) }
    }

    /// The adapter dropped a patch for a path outside the schema.
    func recordDroppedPatch() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
    }
}
