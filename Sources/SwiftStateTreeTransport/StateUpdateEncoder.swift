import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

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

/// JSON object-based state update encoder.
public struct JSONStateUpdateEncoder: StateUpdateEncoder {
    public let encoding: StateUpdateEncoding = .jsonObject

    /// Per-instance JSONEncoder for encoding operations.
    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
    }

    public func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data {
        try encoder.encode(update)
    }
    
    public func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        // JSON encoder doesn't use playerSlot, just use playerID
        try encode(update: update, landID: landID, playerID: playerID)
    }
}

/// Opcode + JSON array state update encoder.
///
/// Supports two formats:
/// 1. Legacy: `[updateOpcode, playerID, [path, op, value?], ...]`
/// 2. PathHash: `[updateOpcode, playerID, [pathHash, dynamicKey, op, value?], ...]`
///
/// Format is determined by presence of PathHasher during initialization.
public struct OpcodeJSONStateUpdateEncoder: StateUpdateEncoder {
    public let encoding: StateUpdateEncoding = .opcodeJsonArray

    /// Per-instance JSONEncoder for encoding operations.
    private let encoder: JSONEncoder
    
    /// Optional path hasher for compression (nil = legacy format)
    private let pathHasher: PathHasher?

    /// Cache for dynamic keys to support compression (String <-> Int Slot)
    private final class DynamicKeyTable: @unchecked Sendable {
        private var keyToSlot: [String: Int] = [:]
        private var nextSlot: Int = 0
        /// Lock for thread-safety (synchronous access in parallel encoding)
        private let lock = NSLock()
        
        /// Get existing slot or assign new one
        func getSlot(for key: String) -> (slot: Int, isNew: Bool) {
            lock.lock()
            defer { lock.unlock() }
            
            if let existing = keyToSlot[key] {
                return (existing, false)
            }
            let slot = nextSlot
            nextSlot += 1
            keyToSlot[key] = slot
            return (slot, true)
        }
        
        /// Get slot if exists, but mark as NOT new (for Force Definition check)
        /// Used when we just want to look up.
        /// Actually getSlot logic is fine, we handle "isNew" vs "forceDefinition" at call site.
    }

    private struct DynamicKeyScope: Hashable {
        let landID: String
        let playerID: String
    }

    private final class DynamicKeyTableStore: @unchecked Sendable {
        private var tables: [DynamicKeyScope: DynamicKeyTable] = [:]
        private let lock = NSLock()

        func table(for landID: String, playerID: PlayerID, reset: Bool) -> DynamicKeyTable {
            let scope = DynamicKeyScope(landID: landID, playerID: playerID.rawValue)
            lock.lock()
            defer { lock.unlock() }
            
            if reset || tables[scope] == nil {
                let table = DynamicKeyTable()
                tables[scope] = table
                return table
            }

            return tables[scope]!
        }
    }
    
    /// Per-player key tables for this encoder context
    private let keyTableStore = DynamicKeyTableStore()

    public init(pathHasher: PathHasher? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
        self.pathHasher = pathHasher
    }

    public func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: nil)
    }
    
    public func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        let opcode: StateUpdateOpcode
        let patches: [StatePatch]
        let forceDefinition: Bool
        
        switch update {
        case .noChange:
            opcode = .noChange
            patches = []
            forceDefinition = false
        case .firstSync(let diffPatches):
            opcode = .firstSync
            patches = diffPatches
            // Force definition format for all keys in firstSync
            // This ensures new players (or late joiners) get the full mapping
            forceDefinition = true
        case .diff(let diffPatches):
            opcode = .diff
            patches = diffPatches
            forceDefinition = false
        }

        // Use playerSlot if provided, otherwise fall back to playerID string
        let playerIdentifier: AnyCodable
        if let slot = playerSlot {
            playerIdentifier = AnyCodable(slot)
        } else {
            playerIdentifier = AnyCodable(playerID.rawValue)
        }

        var payload: [AnyCodable] = [
            AnyCodable(opcode.rawValue),
            playerIdentifier
        ]
        
        // Include initial state payload if needed (legacy or otherwise)
        // Actually for firstSync we just append patches.
        
        if let hasher = pathHasher {
            let keyTable = keyTableStore.table(for: landID, playerID: playerID, reset: forceDefinition)
            for patch in patches {
                payload.append(AnyCodable(encodePatchWithHash(
                    patch,
                    hasher: hasher,
                    forceDefinition: forceDefinition,
                    keyTable: keyTable
                )))
            }
        } else {
            for patch in patches {
                payload.append(AnyCodable(encodePatchLegacy(patch)))
            }
        }

        return try encoder.encode(payload)
    }
    
    // ... encodePatchLegacy implementation unchanged ...
    private func encodePatchLegacy(_ patch: StatePatch) -> [AnyCodable] {
        switch patch.operation {
        case .set(let value):
            return [
                AnyCodable(patch.path),
                AnyCodable(StatePatchOpcode.set.rawValue),
                AnyCodable(value)
            ]
        case .delete:
            return [
                AnyCodable(patch.path),
                AnyCodable(StatePatchOpcode.remove.rawValue)
            ]
        case .add(let value):
            return [
                AnyCodable(patch.path),
                AnyCodable(StatePatchOpcode.add.rawValue),
                AnyCodable(value)
            ]
        }
    }
    
    private func encodePatchWithHash(
        _ patch: StatePatch,
        hasher: PathHasher,
        forceDefinition: Bool,
        keyTable: DynamicKeyTable
    ) -> [AnyCodable] {
        let (pathHash, dynamicKey) = hasher.split(patch.path)
        
        // Compress dynamicKey if present
        var encodedKey: AnyCodable
        if let key = dynamicKey {
            let (slot, isNew) = keyTable.getSlot(for: key)
            if isNew || forceDefinition {
                // Define-on-first-use OR Force Definition: [slot, "key"]
                encodedKey = AnyCodable([AnyCodable(slot), AnyCodable(key)])
            } else {
                // Subsequent use: slot
                encodedKey = AnyCodable(slot)
            }
        } else {
            encodedKey = AnyCodable(nil as String?)
        }
        
        switch patch.operation {
        case .set(let value):
            return [
                AnyCodable(pathHash),
                encodedKey,
                AnyCodable(StatePatchOpcode.set.rawValue),
                AnyCodable(value)
            ]
        case .delete:
            return [
                AnyCodable(pathHash),
                encodedKey,
                AnyCodable(StatePatchOpcode.remove.rawValue)
            ]
        case .add(let value):
            return [
                AnyCodable(pathHash),
                encodedKey,
                AnyCodable(StatePatchOpcode.add.rawValue),
                AnyCodable(value)
            ]
        }
    }
}

/// Opcode + MessagePack array state update encoder.
///
/// Uses the **same array structure** as `OpcodeJSONStateUpdateEncoder`, but serializes with MessagePack:
/// - Legacy: `[updateOpcode, playerID|playerSlot, [path, op, value?], ...]`
/// - PathHash: `[updateOpcode, playerID|playerSlot, [pathHash, dynamicKey, op, value?], ...]`
///
/// This is intended for `TRANSPORT_ENCODING=messagepack` where state updates should also be binary.
public struct OpcodeMessagePackStateUpdateEncoder: StateUpdateEncoder {
    public let encoding: StateUpdateEncoding = .opcodeMessagePack

    /// Optional path hasher for compression (nil = legacy format)
    private let pathHasher: PathHasher?

    /// Cache for dynamic keys to support compression (String <-> Int Slot)
    private final class DynamicKeyTable: @unchecked Sendable {
        private var keyToSlot: [String: Int] = [:]
        private var nextSlot: Int = 0
        /// Lock for thread-safety (synchronous access in parallel encoding)
        private let lock = NSLock()

        /// Get existing slot or assign new one
        func getSlot(for key: String) -> (slot: Int, isNew: Bool) {
            lock.lock()
            defer { lock.unlock() }

            if let existing = keyToSlot[key] {
                return (existing, false)
            }
            let slot = nextSlot
            nextSlot += 1
            keyToSlot[key] = slot
            return (slot, true)
        }
    }

    private struct DynamicKeyScope: Hashable {
        let landID: String
        let playerID: String
    }

    private final class DynamicKeyTableStore: @unchecked Sendable {
        private var tables: [DynamicKeyScope: DynamicKeyTable] = [:]
        private let lock = NSLock()

        func table(for landID: String, playerID: PlayerID, reset: Bool) -> DynamicKeyTable {
            let scope = DynamicKeyScope(landID: landID, playerID: playerID.rawValue)
            lock.lock()
            defer { lock.unlock() }

            if reset || tables[scope] == nil {
                let table = DynamicKeyTable()
                tables[scope] = table
                return table
            }

            return tables[scope]!
        }
    }

    /// Per-player key tables for this encoder context
    private let keyTableStore = DynamicKeyTableStore()

    public init(pathHasher: PathHasher? = nil) {
        self.pathHasher = pathHasher
    }

    public func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: nil)
    }

    public func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        let opcode: StateUpdateOpcode
        let patches: [StatePatch]
        let forceDefinition: Bool

        switch update {
        case .noChange:
            opcode = .noChange
            patches = []
            forceDefinition = false
        case .firstSync(let diffPatches):
            opcode = .firstSync
            patches = diffPatches
            // Force definition format for all keys in firstSync
            forceDefinition = true
        case .diff(let diffPatches):
            opcode = .diff
            patches = diffPatches
            forceDefinition = false
        }

        // Use playerSlot if provided, otherwise fall back to playerID string
        let playerIdentifier: AnyCodable
        if let slot = playerSlot {
            playerIdentifier = AnyCodable(slot)
        } else {
            playerIdentifier = AnyCodable(playerID.rawValue)
        }

        var payload: [AnyCodable] = [
            AnyCodable(opcode.rawValue),
            playerIdentifier
        ]

        if let hasher = pathHasher {
            let keyTable = keyTableStore.table(for: landID, playerID: playerID, reset: forceDefinition)
            for patch in patches {
                payload.append(AnyCodable(encodePatchWithHash(
                    patch,
                    hasher: hasher,
                    forceDefinition: forceDefinition,
                    keyTable: keyTable
                )))
            }
        } else {
            for patch in patches {
                payload.append(AnyCodable(encodePatchLegacy(patch)))
            }
        }

        let encoder = MessagePackValueEncoder()
        let values = try payload.map { try encoder.encode($0) }
        return try pack(.array(values))
    }

    private func encodePatchLegacy(_ patch: StatePatch) -> [AnyCodable] {
        switch patch.operation {
        case .set(let value):
            return [
                AnyCodable(patch.path),
                AnyCodable(StatePatchOpcode.set.rawValue),
                AnyCodable(value)
            ]
        case .delete:
            return [
                AnyCodable(patch.path),
                AnyCodable(StatePatchOpcode.remove.rawValue)
            ]
        case .add(let value):
            return [
                AnyCodable(patch.path),
                AnyCodable(StatePatchOpcode.add.rawValue),
                AnyCodable(value)
            ]
        }
    }

    private func encodePatchWithHash(
        _ patch: StatePatch,
        hasher: PathHasher,
        forceDefinition: Bool,
        keyTable: DynamicKeyTable
    ) -> [AnyCodable] {
        let (pathHash, dynamicKey) = hasher.split(patch.path)

        // Compress dynamicKey if present
        let encodedKey: AnyCodable
        if let key = dynamicKey {
            let (slot, isNew) = keyTable.getSlot(for: key)
            if isNew || forceDefinition {
                // Define-on-first-use OR Force Definition: [slot, "key"]
                encodedKey = AnyCodable([AnyCodable(slot), AnyCodable(key)])
            } else {
                // Subsequent use: slot
                encodedKey = AnyCodable(slot)
            }
        } else {
            encodedKey = AnyCodable(nil as String?)
        }

        switch patch.operation {
        case .set(let value):
            return [
                AnyCodable(pathHash),
                encodedKey,
                AnyCodable(StatePatchOpcode.set.rawValue),
                AnyCodable(value)
            ]
        case .delete:
            return [
                AnyCodable(pathHash),
                encodedKey,
                AnyCodable(StatePatchOpcode.remove.rawValue)
            ]
        case .add(let value):
            return [
                AnyCodable(pathHash),
                encodedKey,
                AnyCodable(StatePatchOpcode.add.rawValue),
                AnyCodable(value)
            ]
        }
    }
}
