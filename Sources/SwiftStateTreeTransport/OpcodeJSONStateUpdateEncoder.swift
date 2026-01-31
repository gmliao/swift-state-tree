import Foundation
import SwiftStateTree

/// Opcode + JSON array state update encoder.
///
/// Supports two formats:
/// 1. Legacy: `[updateOpcode, playerID, [path, op, value?], ...]`
/// 2. PathHash: `[updateOpcode, playerID, [pathHash, dynamicKey, op, value?], ...]`
///
/// Format is determined by presence of PathHasher during initialization.
public struct OpcodeJSONStateUpdateEncoder: StateUpdateEncoderWithScope {
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

    private enum DynamicKeyScope: Hashable {
        case broadcast(landID: String)
        case perPlayer(landID: String, playerID: String)
    }

    private final class DynamicKeyTableStore: @unchecked Sendable {
        private var tables: [DynamicKeyScope: DynamicKeyTable] = [:]
        private let lock = NSLock()

        func table(for scope: DynamicKeyScope, reset: Bool) -> DynamicKeyTable {
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
        try encode(
            update: update,
            landID: landID,
            playerID: playerID,
            playerSlot: playerSlot,
            scope: .perPlayer
        )
    }

    public func encode(
        update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope
    ) throws -> Data {
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

        let keyScope: DynamicKeyScope = {
            switch scope {
            case .broadcast:
                return .broadcast(landID: landID)
            case .perPlayer:
                return .perPlayer(landID: landID, playerID: playerID.rawValue)
            }
        }()

        // Optimized: Direct encoding without recursion
        // Use custom Codable struct to encode array directly
        let payload = OpcodePayloadArray(
            opcode: opcode.rawValue,
            patches: patches,
            pathHasher: pathHasher,
            keyTableStore: pathHasher != nil ? keyTableStore : nil,
            keyTableScope: keyScope,
            forceDefinition: forceDefinition
        )

        return try encoder.encode(payload)
    }
    
    // MARK: - Optimized Encoding (without recursion)
    
    /// Direct encoding structure that avoids recursive enum wrapping
    /// Encodes as: [opcode, [patch1], [patch2], ...]
    private struct OpcodePayloadArray: Codable {
        let opcode: Int
        let patches: [StatePatch]
        let pathHasher: PathHasher?
        let keyTableStore: DynamicKeyTableStore?
        let keyTableScope: DynamicKeyScope
        let forceDefinition: Bool
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            
            // Encode opcode
            try container.encode(opcode)
            
            // Encode patches directly without recursion
            if let hasher = pathHasher, let keyTableStore = keyTableStore {
                let keyTable = keyTableStore.table(for: keyTableScope, reset: forceDefinition)
                for patch in patches {
                    var patchContainer = container.nestedUnkeyedContainer()
                    try encodePatchWithHashDirect(
                        patch,
                        hasher: hasher,
                        forceDefinition: forceDefinition,
                        keyTable: keyTable,
                        into: &patchContainer
                    )
                }
            } else {
                for patch in patches {
                    var patchContainer = container.nestedUnkeyedContainer()
                    try encodePatchLegacyDirect(patch, into: &patchContainer)
                }
            }
        }
        
        // Helper methods for encoding patches
        private func encodePatchLegacyDirect(
            _ patch: StatePatch,
            into container: inout UnkeyedEncodingContainer
        ) throws {
            try container.encode(patch.path)
            switch patch.operation {
            case .set(let value):
                try container.encode(StatePatchOpcode.set.rawValue)
                try container.encode(value)
            case .delete:
                try container.encode(StatePatchOpcode.remove.rawValue)
            case .add(let value):
                try container.encode(StatePatchOpcode.add.rawValue)
                try container.encode(value)
            }
        }
        
        private func encodePatchWithHashDirect(
            _ patch: StatePatch,
            hasher: PathHasher,
            forceDefinition: Bool,
            keyTable: DynamicKeyTable,
            into container: inout UnkeyedEncodingContainer
        ) throws {
            let (pathHash, dynamicKeys) = hasher.split(patch.path)
            
            // Encode pathHash
            try container.encode(Int(pathHash))
            
            // Encode dynamicKeys directly
            switch dynamicKeys.count {
            case 0:
                try container.encodeNil()
            case 1:
                // Single key: encode directly (slot or [slot, key])
                let (slot, isNew) = keyTable.getSlot(for: dynamicKeys[0])
                if isNew || forceDefinition {
                    var keyContainer = container.nestedUnkeyedContainer()
                    try keyContainer.encode(slot)
                    try keyContainer.encode(dynamicKeys[0])
                } else {
                    try container.encode(slot)
                }
            default:
                // Multiple keys: encode as array
                var keysContainer = container.nestedUnkeyedContainer()
                for key in dynamicKeys {
                    let (slot, isNew) = keyTable.getSlot(for: key)
                    if isNew || forceDefinition {
                        var keyItemContainer = keysContainer.nestedUnkeyedContainer()
                        try keyItemContainer.encode(slot)
                        try keyItemContainer.encode(key)
                    } else {
                        try keysContainer.encode(slot)
                    }
                }
            }
            
            // Encode operation
            switch patch.operation {
            case .set(let value):
                try container.encode(StatePatchOpcode.set.rawValue)
                try container.encode(value)
            case .delete:
                try container.encode(StatePatchOpcode.remove.rawValue)
            case .add(let value):
                try container.encode(StatePatchOpcode.add.rawValue)
                try container.encode(value)
            }
        }
        
        init(
            opcode: Int,
            patches: [StatePatch],
            pathHasher: PathHasher?,
            keyTableStore: DynamicKeyTableStore?,
            keyTableScope: DynamicKeyScope,
            forceDefinition: Bool
        ) {
            self.opcode = opcode
            self.patches = patches
            self.pathHasher = pathHasher
            self.keyTableStore = keyTableStore
            self.keyTableScope = keyTableScope
            self.forceDefinition = forceDefinition
        }
        
        init(from decoder: Decoder) throws {
            // Decoding not needed for encoding-only use case
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "OpcodePayloadArray is encoding-only"
                )
            )
        }
    }
    
    /// Direct encoding of patch without recursion - encodes into unkeyedContainer
    private func encodePatchLegacyDirect(
        _ patch: StatePatch,
        into container: inout UnkeyedEncodingContainer
    ) throws {
        try container.encode(patch.path)
        switch patch.operation {
        case .set(let value):
            try container.encode(StatePatchOpcode.set.rawValue)
            try container.encode(value)
        case .delete:
            try container.encode(StatePatchOpcode.remove.rawValue)
        case .add(let value):
            try container.encode(StatePatchOpcode.add.rawValue)
            try container.encode(value)
        }
    }
    
    // Legacy method kept for compatibility (not used in optimized path)
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
    
    /// Direct encoding of patch with hash without recursion
    private func encodePatchWithHashDirect(
        _ patch: StatePatch,
        hasher: PathHasher,
        forceDefinition: Bool,
        keyTable: DynamicKeyTable,
        into container: inout UnkeyedEncodingContainer
    ) throws {
        let (pathHash, dynamicKeys) = hasher.split(patch.path)
        
        // Encode pathHash
        try container.encode(Int(pathHash))
        
        // Encode dynamicKeys directly
        func encodeDynamicKey(_ key: String, into keyContainer: inout UnkeyedEncodingContainer) throws {
            let (slot, isNew) = keyTable.getSlot(for: key)
            if isNew || forceDefinition {
                // Define-on-first-use OR Force Definition: [slot, "key"]
                try keyContainer.encode(slot)
                try keyContainer.encode(key)
            } else {
                // Subsequent use: slot
                try keyContainer.encode(slot)
            }
        }
        
        // Compress dynamicKeys if present
        switch dynamicKeys.count {
        case 0:
            try container.encodeNil()
        case 1:
            // Single key: encode directly (slot or [slot, key])
            let (slot, isNew) = keyTable.getSlot(for: dynamicKeys[0])
            if isNew || forceDefinition {
                var keyContainer = container.nestedUnkeyedContainer()
                try keyContainer.encode(slot)
                try keyContainer.encode(dynamicKeys[0])
            } else {
                try container.encode(slot)
            }
        default:
            // Multiple keys: encode as array
            var keysContainer = container.nestedUnkeyedContainer()
            for key in dynamicKeys {
                try encodeDynamicKey(key, into: &keysContainer)
            }
        }
        
        // Encode operation
        switch patch.operation {
        case .set(let value):
            try container.encode(StatePatchOpcode.set.rawValue)
            try container.encode(value)
        case .delete:
            try container.encode(StatePatchOpcode.remove.rawValue)
        case .add(let value):
            try container.encode(StatePatchOpcode.add.rawValue)
            try container.encode(value)
        }
    }
    
    private func encodePatchWithHash(
        _ patch: StatePatch,
        hasher: PathHasher,
        forceDefinition: Bool,
        keyTable: DynamicKeyTable
    ) -> [AnyCodable] {
        let (pathHash, dynamicKeys) = hasher.split(patch.path)

        func encodeDynamicKey(_ key: String) -> AnyCodable {
            let (slot, isNew) = keyTable.getSlot(for: key)
            if isNew || forceDefinition {
                // Define-on-first-use OR Force Definition: [slot, "key"]
                return AnyCodable([AnyCodable(slot), AnyCodable(key)])
            }
            // Subsequent use: slot
            return AnyCodable(slot)
        }

        // Compress dynamicKeys if present
        let encodedKey: AnyCodable
        switch dynamicKeys.count {
        case 0:
            encodedKey = AnyCodable(nil as String?)
        case 1:
            encodedKey = encodeDynamicKey(dynamicKeys[0])
        default:
            encodedKey = AnyCodable(dynamicKeys.map { encodeDynamicKey($0) })
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
