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
public struct OpcodeMessagePackStateUpdateEncoder: SyncSequencedStateUpdateEncoder {
    public let encoding: StateUpdateEncoding = .opcodeMessagePack

    /// Optional path hasher for compression (nil = legacy format)
    let pathHasher: PathHasher?

    /// With a path hasher: send a dynamic key as `[slot, "key"]` on first use and `slot` after it
    /// (true), or always as the full key string (false). Measured separately from path hashing.
    public let dynamicKeyCompression: Bool

    /// The state's atomic values, sent positionally (`AtomicPositionalForm`); `nil` sends them
    /// keyed (`TransportEncodingConfig.atomicValues == .keyed`).
    public let atomicLayout: AtomicLayoutTable?

    /// With a path hasher: send a pattern's path index (its rank among the land's sorted schema
    /// path hashes, `PathHasher.sortedHashes`) instead of its 32-bit hash. A path outside the
    /// schema then fails the frame (`StateUpdateEncodingError.pathNotInSchema`).
    public let pathIndex: Bool

    /// Records a patch whose path has no index (with `pathIndex` on).
    public let unmappedPaths: UnmappedPathCounter?

    /// With a path hasher: merge patches that set (or add) fields of one parent into one entry
    /// (`MergedPatchOpcode`, `FieldMergeTable`); nil sends one entry per patch.
    public let fieldMerge: FieldMergeTable?
    /// The recipients of one sync start with the same broadcast patches; their splits (and, with
    /// field merge, their plans) share it.
    let framePrefixCache = FramePrefixCache()
    /// Each frame's patches go out in the land's canonical order (`CanonicalFrameOrder`), which
    /// the adapter always gives (`withCanonicalOrder`). An encoder used on its own (field-merge
    /// fixtures, planner tests) keeps the order it is given.
    package private(set) var canonicalOrder: CanonicalFrameOrder?

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

    public init(
        pathHasher: PathHasher? = nil,
        dynamicKeyCompression: Bool = true,
        atomicLayout: AtomicLayoutTable? = nil,
        pathIndex: Bool = false,
        unmappedPaths: UnmappedPathCounter? = nil,
        fieldMerge: FieldMergeTable? = nil
    ) {
        self.pathHasher = pathHasher
        self.dynamicKeyCompression = dynamicKeyCompression
        self.atomicLayout = atomicLayout
        self.pathIndex = pathIndex
        self.unmappedPaths = unmappedPaths
        self.fieldMerge = fieldMerge
        self.canonicalOrder = nil
    }

    /// This encoder with the land's canonical order.
    package func withCanonicalOrder(_ order: CanonicalPatchOrder) -> Self {
        var copy = self
        copy.canonicalOrder = CanonicalFrameOrder(order: order, pathHashes: pathHasher?.pathHashes)
        return copy
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
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: scope, syncSeq: nil, resync: false)
    }

    public func encode(
        update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope,
        syncSeq: UInt64?,
        resync: Bool
    ) throws -> Data {
        try pack(.array(try encodeToMessagePackArray(
            update: update,
            landID: landID,
            playerID: playerID,
            playerSlot: playerSlot,
            scope: scope,
            syncSeq: syncSeq,
            resync: resync
        )))
    }

    /// Encode a state update into a MessagePack array without serializing to Data.
    /// This is used to build opcode 107 frames without an extra unpack step.
    func encodeToMessagePackArray(
        update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope,
        syncSeq: UInt64? = nil,
        resync: Bool = false
    ) throws -> [MessagePackValue] {
        let opcode: StateUpdateOpcode
        let patches: [StatePatch]
        let forceDefinition: Bool

        switch update {
        case .noChange:
            opcode = .noChange
            patches = []
            forceDefinition = false
        case .firstSync(let diffPatches):
            opcode = resync ? .resync : .firstSync
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
        if let syncSeq {
            payload.append(.uint(syncSeq))
        }

        if let hasher = pathHasher {
            let keyScope: DynamicKeyScope = {
                switch scope {
                case .broadcast:
                    return .broadcast(landID: landID)
                case .perPlayer:
                    return .perPlayer(landID: landID, playerID: playerID.rawValue)
                }
            }()
            // Without compression no slot is assigned, so the table is not touched.
            let keyTable = dynamicKeyCompression ? keyTableStore.table(for: keyScope, reset: forceDefinition) : nil
            let (order, splits, entries) = FieldMergePlan.splitsAndEntries(
                patches: patches, hasher: hasher, table: fieldMerge, cache: framePrefixCache, order: canonicalOrder
            )
            let ordered = order.map { patches[$0] }
            // Slots for this frame's new keys in byte order, not in patch order (#292).
            keyTable?.reserve(splits.lazy.flatMap { $0.dynamicKeys })
            for entry in entries {
                switch entry {
                case .plain(let index):
                    payload.append(.array(try encodePatchWithHashDirect(
                        ordered[index],
                        split: splits[index],
                        hasher: hasher,
                        forceDefinition: forceDefinition,
                        keyTable: keyTable
                    )))
                case .merged(let parentHash, let dynamicKeys, let op, let members):
                    // [parentId, dynamicKey, op, fieldMask, v1, v2, …], values in bit order.
                    var entry: [MessagePackValue] = [
                        try pathID(parentHash, inSchema: true, path: ordered[members[0].index].path, hasher: hasher),
                        encodedDynamicKeys(dynamicKeys, forceDefinition: forceDefinition, keyTable: keyTable),
                        .int(Int64(op.rawValue)),
                        .uint(UInt64(FieldMergeEntry.mask(members))),
                    ]
                    for member in members {
                        let patch = ordered[member.index]
                        switch patch.operation {
                        case .set(let value), .add(let value):
                            entry.append(try wireValue(value, path: patch.path))
                        case .delete:
                            preconditionFailure("a delete is never merged")
                        }
                    }
                    payload.append(.array(entry))
                }
            }
        } else {
            for patch in canonicalOrder?.sorted(patches) ?? patches {
                payload.append(.array(try encodePatchLegacyDirect(patch)))
            }
        }

        return payload
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
    
    /// A patch value on the wire: atomic values positional when `atomicLayout` is set.
    @inline(__always)
    private func wireValue(_ value: SnapshotValue, path: String) throws -> MessagePackValue {
        guard let atomicLayout else { return encodeSnapshotValueToMessagePack(value) }
        return encodeSnapshotValueToMessagePack(try atomicLayout.positional(value, atPath: path))
    }

    /// Direct encoding of patch without AnyCodable - returns MessagePackValue array
    private func encodePatchLegacyDirect(_ patch: StatePatch) throws -> [MessagePackValue] {
        switch patch.operation {
        case .set(let value):
            return [
                .string(patch.path),
                .int(Int64(StatePatchOpcode.set.rawValue)),
                try wireValue(value, path: patch.path)
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
                try wireValue(value, path: patch.path)
            ]
        }
    }
    
    /// Direct encoding of patch with hash without AnyCodable - returns MessagePackValue array
    private func encodePatchWithHashDirect(
        _ patch: StatePatch,
        split: (pathHash: UInt32, dynamicKeys: [String], inSchema: Bool),
        hasher: PathHasher,
        forceDefinition: Bool,
        keyTable: DynamicKeyTable?
    ) throws -> [MessagePackValue] {
        let pathID = try pathID(split.pathHash, inSchema: split.inSchema, path: patch.path, hasher: hasher)
        let encodedKey = encodedDynamicKeys(split.dynamicKeys, forceDefinition: forceDefinition, keyTable: keyTable)

        switch patch.operation {
        case .set(let value):
            return [
                pathID,
                encodedKey,
                .int(Int64(StatePatchOpcode.set.rawValue)),
                try wireValue(value, path: patch.path)
            ]
        case .delete:
            return [
                pathID,
                encodedKey,
                .int(Int64(StatePatchOpcode.remove.rawValue))
            ]
        case .add(let value):
            return [
                pathID,
                encodedKey,
                .int(Int64(StatePatchOpcode.add.rawValue)),
                try wireValue(value, path: patch.path)
            ]
        }
    }
    
    /// The path id: the path index, or the pattern's hash.
    private func pathID(_ pathHash: UInt32, inSchema: Bool, path: String, hasher: PathHasher) throws -> MessagePackValue {
        guard pathIndex else { return .uint(UInt64(pathHash)) }
        // A path outside the schema has no index, even if its fallback hash equals a schema
        // hash. (A merged entry's parent comes from the schema.)
        guard inSchema, let index = hasher.pathIndex(of: pathHash) else {
            unmappedPaths?.noteUnmapped(path: path, hash: pathHash)
            throw StateUpdateEncodingError.pathNotInSchema(path)
        }
        return .uint(UInt64(index))
    }

    /// The dynamic keys: nil, a slot, `[slot, key]`, or an array of those; without
    /// compression, the keys as strings.
    private func encodedDynamicKeys(
        _ dynamicKeys: [String],
        forceDefinition: Bool,
        keyTable: DynamicKeyTable?
    ) -> MessagePackValue {
        func encodeDynamicKey(_ key: String) -> MessagePackValue {
            // Compression off: the full key string.
            guard let keyTable else { return .string(key) }
            let (slot, isNew) = keyTable.getSlot(for: key)
            if isNew || forceDefinition {
                // Define-on-first-use OR Force Definition: [slot, "key"]
                return .array([.int(Int64(slot)), .string(key)])
            }
            // Subsequent use: slot
            return .int(Int64(slot))
        }
        switch dynamicKeys.count {
        case 0:
            return .nil
        case 1:
            return encodeDynamicKey(dynamicKeys[0])
        default:
            return .array(dynamicKeys.map { encodeDynamicKey($0) })
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

extension OpcodeMessagePackStateUpdateEncoder: DynamicKeyTableReporting {
    package var keepsDynamicKeyTables: Bool { dynamicKeyCompression && pathHasher != nil }
}
