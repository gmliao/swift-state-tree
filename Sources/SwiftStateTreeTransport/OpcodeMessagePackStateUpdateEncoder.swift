import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

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

        // Optimized: Direct encoding without AnyCodable
        // Build MessagePackValue array directly
        var payload: [MessagePackValue] = [
            .int(Int64(opcode.rawValue))
        ]

        if let hasher = pathHasher {
            let keyTable = keyTableStore.table(for: landID, playerID: playerID, reset: forceDefinition)
            for patch in patches {
                payload.append(.array(encodePatchWithHashDirect(
                    patch,
                    hasher: hasher,
                    forceDefinition: forceDefinition,
                    keyTable: keyTable
                )))
            }
        } else {
            for patch in patches {
                payload.append(.array(encodePatchLegacyDirect(patch)))
            }
        }

        return try pack(.array(payload))
    }

    // MARK: - Optimized Direct Encoding (without AnyCodable)
    
    /// Convert SnapshotValue to MessagePackValue directly
    private func encodeSnapshotValueToMessagePack(_ value: SnapshotValue) -> MessagePackValue {
        switch value {
        case .null:
            return .nil
        case .bool(let val):
            return .bool(val)
        case .int(let val):
            return .int(Int64(val))
        case .double(let val):
            return .double(val)
        case .string(let val):
            return .string(val)
        case .array(let values):
            return .array(values.map { encodeSnapshotValueToMessagePack($0) })
        case .object(let values):
            var map: [MessagePackValue: MessagePackValue] = [:]
            for (key, val) in values {
                map[.string(key)] = encodeSnapshotValueToMessagePack(val)
            }
            return .map(map)
        }
    }
    
    /// Direct encoding of patch without AnyCodable - returns MessagePackValue array
    private func encodePatchLegacyDirect(_ patch: StatePatch) -> [MessagePackValue] {
        switch patch.operation {
        case .set(let value):
            return [
                .string(patch.path),
                .int(Int64(StatePatchOpcode.set.rawValue)),
                encodeSnapshotValueToMessagePack(value)
            ]
        case .delete:
            return [
                .string(patch.path),
                .int(Int64(StatePatchOpcode.remove.rawValue))
            ]
        case .add(let value):
            return [
                .string(patch.path),
                .int(Int64(StatePatchOpcode.add.rawValue)),
                encodeSnapshotValueToMessagePack(value)
            ]
        }
    }
    
    /// Direct encoding of patch with hash without AnyCodable - returns MessagePackValue array
    private func encodePatchWithHashDirect(
        _ patch: StatePatch,
        hasher: PathHasher,
        forceDefinition: Bool,
        keyTable: DynamicKeyTable
    ) -> [MessagePackValue] {
        let (pathHash, dynamicKeys) = hasher.split(patch.path)

        func encodeDynamicKey(_ key: String) -> MessagePackValue {
            let (slot, isNew) = keyTable.getSlot(for: key)
            if isNew || forceDefinition {
                // Define-on-first-use OR Force Definition: [slot, "key"]
                return .array([.int(Int64(slot)), .string(key)])
            }
            // Subsequent use: slot
            return .int(Int64(slot))
        }

        // Compress dynamicKeys if present
        let encodedKey: MessagePackValue
        switch dynamicKeys.count {
        case 0:
            encodedKey = .nil
        case 1:
            encodedKey = encodeDynamicKey(dynamicKeys[0])
        default:
            encodedKey = .array(dynamicKeys.map { encodeDynamicKey($0) })
        }

        switch patch.operation {
        case .set(let value):
            return [
                .uint(UInt64(pathHash)),
                encodedKey,
                .int(Int64(StatePatchOpcode.set.rawValue)),
                encodeSnapshotValueToMessagePack(value)
            ]
        case .delete:
            return [
                .uint(UInt64(pathHash)),
                encodedKey,
                .int(Int64(StatePatchOpcode.remove.rawValue))
            ]
        case .add(let value):
            return [
                .uint(UInt64(pathHash)),
                encodedKey,
                .int(Int64(StatePatchOpcode.add.rawValue)),
                encodeSnapshotValueToMessagePack(value)
            ]
        }
    }
    
    // Legacy methods kept for compatibility (not used in optimized path)
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
