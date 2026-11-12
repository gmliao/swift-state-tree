import Foundation
import SwiftStateTree

/// Opcode + JSON array state update encoder.
///
/// Supports two formats:
/// 1. Legacy: `[updateOpcode, playerID, [path, op, value?], ...]`
/// 2. PathHash: `[updateOpcode, playerID, [pathHash, dynamicKey, op, value?], ...]`
///
/// Format is determined by presence of PathHasher during initialization.
public struct OpcodeJSONStateUpdateEncoder: SyncSequencedStateUpdateEncoder {
    public let encoding: StateUpdateEncoding = .opcodeJsonArray

    /// Per-instance JSONEncoder for encoding operations.
    private let encoder: JSONEncoder
    
    /// Optional path hasher for compression (nil = legacy format)
    let pathHasher: PathHasher?

    /// With a path hasher: send a dynamic key as `[slot, "key"]` on first use and `slot` after it
    /// (true), or always as the full key string (false). Measured separately from path hashing.
    public let dynamicKeyCompression: Bool

    /// The state's atomic values, sent positionally (`AtomicPositionalForm`); `nil` sends them
    /// keyed (`TransportEncodingConfig.atomicValues == .keyed`).
    public let atomicLayout: AtomicLayoutTable?

    /// `atomicLayout`'s position of each of the hasher's patterns, so a value's position comes
    /// from its split instead of a walk of its path; nil without a hasher or a layout.
    let atomicPatterns: AtomicPatternIndex?

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
        self.init(
            pathHasher: pathHasher, dynamicKeyCompression: dynamicKeyCompression, atomicLayout: atomicLayout,
            pathIndex: pathIndex, unmappedPaths: unmappedPaths, fieldMerge: fieldMerge, atomicPatternIndex: true
        )
    }

    /// `atomicPatternIndex: false` finds each atomic value's position by walking its path, as
    /// an encoder without a hasher does (tests compare the two).
    package init(
        pathHasher: PathHasher?,
        dynamicKeyCompression: Bool,
        atomicLayout: AtomicLayoutTable?,
        pathIndex: Bool,
        unmappedPaths: UnmappedPathCounter?,
        fieldMerge: FieldMergeTable?,
        atomicPatternIndex: Bool
    ) {
        let encoder = JSONEncoder()
        // Object keys in UTF-8 byte order, not hash order, so a frame's bytes don't depend on
        // the process (pinned by `CanonicalEmitOrderTests`).
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.pathHasher = pathHasher
        self.dynamicKeyCompression = dynamicKeyCompression
        self.atomicLayout = atomicLayout
        if atomicPatternIndex, let pathHasher, let atomicLayout {
            self.atomicPatterns = AtomicPatternIndex(table: atomicLayout, hasher: pathHasher)
        } else {
            self.atomicPatterns = nil
        }
        self.pathIndex = pathIndex
        self.unmappedPaths = unmappedPaths
        self.fieldMerge = fieldMerge
        self.canonicalOrder = nil
    }

    /// Each frame's patches go out in the land's canonical order (`CanonicalFrameOrder`), which
    /// the adapter always gives (`withCanonicalOrder`). An encoder used on its own (field-merge
    /// fixtures, planner tests) keeps the order it is given.
    package private(set) var canonicalOrder: CanonicalFrameOrder?

    /// With a path hasher: a patch the typed diff tagged with its row (`PatchSplit.row`) goes out
    /// as a row entry (`RowPatchOpcode`, `RowEntryPlan`), after the frame's other entries.
    package private(set) var rowAddressing = false

    /// This encoder with row entries on or off.
    package func withRowAddressing(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.rowAddressing = enabled
        return copy
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
        var payload = OpcodePayloadArray(
            opcode: opcode.rawValue,
            patches: patches,
            pathHasher: pathHasher,
            keyTableStore: pathHasher != nil ? keyTableStore : nil,
            keyTableScope: keyScope,
            forceDefinition: forceDefinition,
            dynamicKeyCompression: dynamicKeyCompression,
            atomicLayout: atomicLayout,
            atomicPatterns: atomicPatterns
        )
        payload.pathIndex = pathIndex
        payload.unmappedPaths = unmappedPaths
        payload.fieldMerge = fieldMerge
        payload.framePrefixCache = framePrefixCache
        payload.syncSeq = syncSeq
        payload.canonicalOrder = canonicalOrder
        payload.rowAddressing = rowAddressing

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
        let dynamicKeyCompression: Bool
        let atomicLayout: AtomicLayoutTable?
        /// See `OpcodeJSONStateUpdateEncoder.atomicPatterns`.
        let atomicPatterns: AtomicPatternIndex?
        /// See `OpcodeJSONStateUpdateEncoder.pathIndex`.
        var pathIndex = false
        var unmappedPaths: UnmappedPathCounter?
        /// See `OpcodeJSONStateUpdateEncoder.fieldMerge`.
        var fieldMerge: FieldMergeTable?
        var framePrefixCache: FramePrefixCache?
        /// Written right after the opcode when set (`[opcode, seq, patch...]`).
        var syncSeq: UInt64?
        var canonicalOrder: CanonicalFrameOrder?
        /// See `OpcodeJSONStateUpdateEncoder.rowAddressing`.
        var rowAddressing = false

        /// A patch value on the wire: atomic values positional when `atomicLayout` is set.
        @inline(__always)
        private func wireValue(_ value: SnapshotValue, path: String) throws -> SnapshotValue {
            guard let atomicLayout else { return value }
            return try atomicLayout.positional(value, atPath: path)
        }

        /// `wireValue(_:path:)` for a path with this split (by `pathHasher`): the position
        /// comes from `atomicPatterns` when it has one.
        @inline(__always)
        private func wireValue(_ value: SnapshotValue, path: String, pathHash: UInt32, inSchema: Bool) throws -> SnapshotValue {
            guard let atomicPatterns else { return try wireValue(value, path: path) }
            return try atomicPatterns.positional(value, pathHash: pathHash, inSchema: inSchema, path: path)
        }

        @inline(__always)
        private func wireValue(_ value: SnapshotValue, path: String, split: FieldMergeSplit) throws -> SnapshotValue {
            try wireValue(value, path: path, pathHash: split.pathHash, inSchema: split.inSchema)
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            
            // Encode opcode
            try container.encode(opcode)
            if let syncSeq {
                try container.encode(syncSeq)
            }
            
            // Encode patches directly without recursion
            if let hasher = pathHasher, let keyTableStore = keyTableStore {
                // Without compression no slot is assigned, so the table is not touched.
                let keyTable = dynamicKeyCompression
                    ? keyTableStore.table(for: keyTableScope, reset: forceDefinition)
                    : nil
                let rowPlan = rowAddressing
                    ? RowEntryPlan.plan(patches: patches, hasher: hasher, id: { hasher.pathIndex(of: $0) ?? Int($0) })
                    : (rest: patches, rows: [])
                let (order, splits, entries) = FieldMergePlan.splitsAndEntries(
                    patches: rowPlan.rest, hasher: hasher, table: fieldMerge, cache: framePrefixCache, order: canonicalOrder
                )
                let ordered = order.map { rowPlan.rest[$0] }
                // Slots for this frame's new keys in byte order, not in patch order (#292).
                keyTable?.reserve(splits.lazy.flatMap { $0.dynamicKeys })
                for entry in entries {
                    var patchContainer = container.nestedUnkeyedContainer()
                    switch entry {
                    case .plain(let index):
                        try encodePatchWithHashDirect(
                            ordered[index],
                            split: splits[index],
                            hasher: hasher,
                            forceDefinition: forceDefinition,
                            keyTable: keyTable,
                            into: &patchContainer
                        )
                    case .merged(let parentHash, let dynamicKeys, let op, let members):
                        // [parentId, dynamicKey, op, fieldMask, v1, v2, …], values in bit order.
                        try encodePathID(parentHash, inSchema: true, path: ordered[members[0].index].path, hasher: hasher, into: &patchContainer)
                        try encodeDynamicKeys(dynamicKeys, forceDefinition: forceDefinition, keyTable: keyTable, into: &patchContainer)
                        try patchContainer.encode(op.rawValue)
                        try patchContainer.encode(FieldMergeEntry.mask(members))
                        for member in members {
                            let patch = ordered[member.index]
                            switch patch.operation {
                            case .set(let value), .add(let value):
                                try patchContainer.encode(wireValue(value, path: patch.path, split: splits[member.index]))
                            case .delete:
                                preconditionFailure("a delete is never merged")
                            }
                        }
                    }
                }
                for row in rowPlan.rows {
                    var rowContainer = container.nestedUnkeyedContainer()
                    try encodeRowEntry(row, hasher: hasher, into: &rowContainer)
                }
            } else {
                for patch in canonicalOrder?.sorted(patches) ?? patches {
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
                try container.encode(wireValue(value, path: patch.path))
            case .delete:
                try container.encode(StatePatchOpcode.remove.rawValue)
            case .add(let value):
                try container.encode(StatePatchOpcode.add.rawValue)
                try container.encode(wireValue(value, path: patch.path))
            }
        }
        
        private func encodePatchWithHashDirect(
            _ patch: StatePatch,
            split: (pathHash: UInt32, dynamicKeys: [String], inSchema: Bool),
            hasher: PathHasher,
            forceDefinition: Bool,
            keyTable: DynamicKeyTable?,
            into container: inout UnkeyedEncodingContainer
        ) throws {
            try encodePathID(split.pathHash, inSchema: split.inSchema, path: patch.path, hasher: hasher, into: &container)
            try encodeDynamicKeys(split.dynamicKeys, forceDefinition: forceDefinition, keyTable: keyTable, into: &container)
            try encodeOperation(patch, split: split, into: &container)
        }

        /// A row entry (`RowPatchOpcode`). The slot stands where a path entry has its dynamic
        /// keys.
        private func encodeRowEntry(_ row: RowEntry, hasher: PathHasher, into container: inout UnkeyedEncodingContainer) throws {
            func value(_ index: Int) throws -> SnapshotValue {
                guard case .set(let value) = patches[index].operation else {
                    preconditionFailure("a create or a column set is a set")
                }
                // A row patch carries its split (`RowEntryPlan` takes no other).
                guard let split = patches[index].split else { return try wireValue(value, path: patches[index].path) }
                return try wireValue(value, path: patches[index].path, pathHash: split.pathHash, inSchema: true)
            }
            switch row {
            case .create(let table, let slot, let generation, let key, let index):
                try encodePathID(table, inSchema: true, path: patches[index].path, hasher: hasher, into: &container)
                try container.encode(slot)
                try container.encode(RowPatchOpcode.create.rawValue)
                try container.encode(generation)
                // The parent row's slot: none for a root table.
                try container.encodeNil()
                try container.encode(key)
                try container.encode(value(index))
            case .delete(let table, let slot, let index):
                try encodePathID(table, inSchema: true, path: patches[index].path, hasher: hasher, into: &container)
                try container.encode(slot)
                try container.encode(RowPatchOpcode.delete.rawValue)
            case .columnSet(let leaf, let members):
                try encodePathID(leaf, inSchema: true, path: patches[members[0].index].path, hasher: hasher, into: &container)
                try container.encode(members.map(\.slot))
                try container.encode(RowPatchOpcode.columnSet.rawValue)
                var values = container.nestedUnkeyedContainer()
                for member in members {
                    try values.encode(value(member.index))
                }
            case .columnClear(let leaf, let members):
                try encodePathID(leaf, inSchema: true, path: patches[members[0].index].path, hasher: hasher, into: &container)
                try container.encode(members.map(\.slot))
                try container.encode(RowPatchOpcode.columnClear.rawValue)
            }
        }

        /// The path id: the path index, or the pattern's hash.
        private func encodePathID(
            _ pathHash: UInt32,
            inSchema: Bool,
            path: String,
            hasher: PathHasher,
            into container: inout UnkeyedEncodingContainer
        ) throws {
            if pathIndex {
                // A path outside the schema has no index, even if its fallback hash equals a
                // schema hash. (A merged entry's parent comes from the schema.)
                guard inSchema, let index = hasher.pathIndex(of: pathHash) else {
                    unmappedPaths?.noteUnmapped(path: path, hash: pathHash)
                    throw StateUpdateEncodingError.pathNotInSchema(path)
                }
                try container.encode(index)
            } else {
                try container.encode(Int(pathHash))
            }
        }

        /// The dynamic keys: nil, a slot, `[slot, key]`, or an array of those; without
        /// compression, nil, the key, or the keys in order.
        private func encodeDynamicKeys(
            _ dynamicKeys: [String],
            forceDefinition: Bool,
            keyTable: DynamicKeyTable?,
            into container: inout UnkeyedEncodingContainer
        ) throws {
            guard let keyTable else {
                switch dynamicKeys.count {
                case 0: try container.encodeNil()
                case 1: try container.encode(dynamicKeys[0])
                default: try container.encode(dynamicKeys)
                }
                return
            }
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
        }

        /// The patch's opcode and, for set and add, its value.
        private func encodeOperation(
            _ patch: StatePatch, split: FieldMergeSplit, into container: inout UnkeyedEncodingContainer
        ) throws {
            switch patch.operation {
            case .set(let value):
                try container.encode(StatePatchOpcode.set.rawValue)
                try container.encode(wireValue(value, path: patch.path, split: split))
            case .delete:
                try container.encode(StatePatchOpcode.remove.rawValue)
            case .add(let value):
                try container.encode(StatePatchOpcode.add.rawValue)
                try container.encode(wireValue(value, path: patch.path, split: split))
            }
        }
        
        init(
            opcode: Int,
            patches: [StatePatch],
            pathHasher: PathHasher?,
            keyTableStore: DynamicKeyTableStore?,
            keyTableScope: DynamicKeyScope,
            forceDefinition: Bool,
            dynamicKeyCompression: Bool,
            atomicLayout: AtomicLayoutTable?,
            atomicPatterns: AtomicPatternIndex?
        ) {
            self.opcode = opcode
            self.patches = patches
            self.pathHasher = pathHasher
            self.keyTableStore = keyTableStore
            self.keyTableScope = keyTableScope
            self.forceDefinition = forceDefinition
            self.dynamicKeyCompression = dynamicKeyCompression
            self.atomicLayout = atomicLayout
            self.atomicPatterns = atomicPatterns
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
