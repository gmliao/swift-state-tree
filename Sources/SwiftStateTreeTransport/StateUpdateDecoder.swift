import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

/// Decoded state update payload with optional routing metadata.
public struct DecodedStateUpdate: Sendable {
    public let update: StateUpdate
    public let landID: String?
    public let playerID: PlayerID?
    /// The land's sync sequence the frame carried (#332), or nil for a frame without one.
    public let syncSeq: UInt64?
    /// The frame was a resync (#332): `update` is the fresh full view, as a `.firstSync`, and the
    /// client replaces its state with it instead of applying it as patches.
    public let resync: Bool

    public init(update: StateUpdate, landID: String? = nil, playerID: PlayerID? = nil, syncSeq: UInt64? = nil, resync: Bool = false) {
        self.update = update
        self.landID = landID
        self.playerID = playerID
        self.syncSeq = syncSeq
        self.resync = resync
    }
}

/// Errors thrown during state update decoding.
public enum StateUpdateDecodingError: Error, Sendable {
    case invalidPayload(String)
}

/// Decodes state updates from transport payloads.
public protocol StateUpdateDecoder: Sendable {
    var encoding: StateUpdateEncoding { get }
    func decode(data: Data) throws -> DecodedStateUpdate
}

/// JSON object-based state update decoder.
public struct JSONStateUpdateDecoder: StateUpdateDecoder {
    public let encoding: StateUpdateEncoding = .jsonObject

    private let decoder: JSONDecoder

    public init() {
        self.decoder = JSONDecoder()
    }

    public func decode(data: Data) throws -> DecodedStateUpdate {
        let fields = try decoder.decode(SequenceFields.self, from: data)
        if fields.type == "resync" {
            guard fields.seq != nil else {
                throw StateUpdateDecodingError.invalidPayload("A resync needs a sync sequence.")
            }
            return DecodedStateUpdate(update: .firstSync(fields.patches ?? []), syncSeq: fields.seq, resync: true)
        }
        let update = try decoder.decode(StateUpdate.self, from: data)
        return DecodedStateUpdate(update: update, syncSeq: fields.seq)
    }
}

/// The JSON object's type, its optional `seq` key, and the patches of a resync.
private struct SequenceFields: Decodable {
    let type: String?
    let seq: UInt64?
    let patches: [StatePatch]?
}

/// The format of a frame given to `OpcodeJSONStateUpdateDecoder.decodeFrame`.
package enum StateFrameFormat: Sendable {
    case json
    case messagePack
}

/// Opcode + JSON array state update decoder.
public struct OpcodeJSONStateUpdateDecoder: StateUpdateDecoder {
    public let encoding: StateUpdateEncoding = .opcodeJsonArray
    
    /// Optional path hasher for PathHash format decoding (nil = legacy format only)
    private let pathHasher: PathHasher?
    
    /// Dynamic key table for PathHash format (slot -> key mapping)
    private final class DynamicKeyTable: @unchecked Sendable {
        private var slotToKey: [Int: String] = [:]
        private let lock = NSLock()
        
        func getKey(for slot: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return slotToKey[slot]
        }
        
        func setKey(_ key: String, for slot: Int) {
            lock.lock()
            defer { lock.unlock() }
            slotToKey[slot] = key
        }
    }
    
    private struct DynamicKeyScope: Hashable {
        let landID: String?
        let playerID: String?
    }
    
    private final class DynamicKeyTableStore: @unchecked Sendable {
        private var tables: [DynamicKeyScope: DynamicKeyTable] = [:]
        private let lock = NSLock()
        
        func table(for landID: String?, playerID: PlayerID?) -> DynamicKeyTable {
            let scope = DynamicKeyScope(landID: landID, playerID: playerID?.rawValue)
            lock.lock()
            defer { lock.unlock() }
            
            if tables[scope] == nil {
                tables[scope] = DynamicKeyTable()
            }
            return tables[scope]!
        }

        /// The table of a frame's key scope (`decodeFrame`), a new one when `reset`.
        func table(for scope: StateUpdateKeyScope, reset: Bool) -> DynamicKeyTable {
            let key = DynamicKeyScope(landID: scope == .broadcast ? "broadcast" : "perPlayer", playerID: nil)
            lock.lock()
            defer { lock.unlock() }
            if reset || tables[key] == nil {
                tables[key] = DynamicKeyTable()
            }
            return tables[key]!
        }
    }
    
    private let keyTableStore = DynamicKeyTableStore()

    /// The rows of the slot-addressed tables, as row entries (`RowPatchOpcode`) bound them: by
    /// the table's pattern hash, slot to key, and each slot's last generation, which outlives
    /// its row.
    private final class RowTables: @unchecked Sendable {
        private var keys: [UInt32: [Int: String]] = [:]
        private var generations: [UInt32: [Int: UInt32]] = [:]
        private let lock = NSLock()

        func key(table: UInt32, slot: Int) -> String? {
            lock.withLock { keys[table]?[slot] }
        }

        func lastGeneration(table: UInt32, slot: Int) -> UInt32? {
            lock.withLock { generations[table]?[slot] }
        }

        func bind(table: UInt32, slot: Int, key: String, generation: UInt32) {
            lock.withLock {
                keys[table, default: [:]][slot] = key
                generations[table, default: [:]][slot] = generation
            }
        }

        func unbind(table: UInt32, slot: Int) {
            lock.withLock { _ = keys[table]?.removeValue(forKey: slot) }
        }

        func clear() {
            lock.withLock {
                keys = [:]
                generations = [:]
            }
        }

        func bound(table: UInt32) -> [Int: (key: String, generation: UInt32)] {
            lock.withLock {
                var result: [Int: (key: String, generation: UInt32)] = [:]
                for (slot, key) in keys[table] ?? [:] {
                    result[slot] = (key, generations[table]?[slot] ?? 0)
                }
                return result
            }
        }
    }

    private let rowTables = RowTables()

    /// The bound rows of the slot-addressed table whose rows have `pattern` (`monsters.*`): slot
    /// to key and generation, as the row entries decoded so far left them.
    package func boundRows(ofPattern pattern: String) -> [Int: (key: String, generation: UInt32)] {
        guard let hash = pathHasher?.pathHashes[pattern] else { return [:] }
        return rowTables.bound(table: hash)
    }

    /// The state's atomic values: a positional value at an atomic path is rebuilt keyed. `nil`
    /// leaves values as they arrive (a keyed server, or a caller that wants the wire form).
    private let atomicLayout: AtomicLayoutTable?

    /// Path ids are path indices (the encoder's `pathIndex`), not hashes.
    private let pathIndex: Bool

    /// The parents' fields by bit, for merged entries (`MergedPatchOpcode`).
    private let fieldMerge: FieldMergeTable?

    /// The frames carry the sync sequence at index 1 (the `syncSequence` feature was negotiated).
    private let syncSequence: Bool

    public init(
        pathHasher: PathHasher? = nil, atomicLayout: AtomicLayoutTable? = nil, pathIndex: Bool = false, syncSequence: Bool = false
    ) {
        self.syncSequence = syncSequence
        self.pathHasher = pathHasher
        self.atomicLayout = atomicLayout
        self.pathIndex = pathIndex
        self.fieldMerge = pathHasher.map { FieldMergeTable(pathHashes: $0.pathHashes) }
    }

    /// `value` received at `path`, in the keyed (logical) form.
    private func logicalValue(_ value: SnapshotValue, path: String) throws -> SnapshotValue {
        guard let atomicLayout else { return value }
        do {
            return try atomicLayout.keyed(value, atPath: path)
        } catch let error as AtomicPositionalFormError {
            throw StateUpdateDecodingError.invalidPayload(error.description)
        }
    }

    public func decode(data: Data) throws -> DecodedStateUpdate {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let payload = json as? [Any] else {
            throw StateUpdateDecodingError.invalidPayload("Expected JSON array payload.")
        }
        // Without a scope: one key table, never cleared (as this entry always was).
        return try decode(payload: payload, keyTable: { _ in keyTableStore.table(for: nil, playerID: nil) })
    }

    /// One recipient's frame, as a client reads it:
    /// - `data` is an opcode JSON array state update, or a MessagePack frame: a state update, or
    ///   the merged frame (`[107, stateUpdate, events]`), whose state update is decoded. Any
    ///   other MessagePack frame (an event, a join response) gives nil.
    /// - The dynamic key table is the frame's scope's: `scope`, or by the frame's kind when nil
    ///   (the merged frame's is the broadcast scope, a state update's the per-player one). A
    ///   firstSync or a resync starts the scope's table again.
    /// - Row entries bind and unbind slots under the strict rules (`decodeRowEntry`); a resync
    ///   clears the rows.
    package func decodeFrame(_ data: Data, format: StateFrameFormat, scope: StateUpdateKeyScope? = nil) throws -> DecodedStateUpdate? {
        let payload: [Any]
        var frameScope = StateUpdateKeyScope.perPlayer
        switch format {
        case .json:
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw StateUpdateDecodingError.invalidPayload("Expected JSON array payload.")
            }
            payload = array
        case .messagePack:
            guard case .array(let frame) = try unpack(data), let kind = frame.first.flatMap(Self.integer) else {
                throw StateUpdateDecodingError.invalidPayload("Expected a MessagePack array frame.")
            }
            if kind == Int64(MessageKindOpcode.stateUpdateWithEvents) {
                guard frame.count > 1, case .array(let state) = frame[1] else {
                    throw StateUpdateDecodingError.invalidPayload("Merged frame without a state update.")
                }
                payload = try state.map(Self.jsonValue)
                frameScope = .broadcast
            } else if StateUpdateOpcode(rawValue: Int(kind)) != nil {
                payload = try frame.map(Self.jsonValue)
            } else {
                return nil
            }
        }
        let keyScope = scope ?? frameScope
        return try decode(payload: payload, keyTable: { opcode in
            keyTableStore.table(for: keyScope, reset: opcode == .firstSync || opcode == .resync)
        })
    }

    private static func integer(_ value: MessagePackValue) -> Int64? {
        switch value {
        case .int(let value): return value
        case .uint(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    /// A MessagePack value as `JSONSerialization` would give the same JSON value, so one entry
    /// reader serves both formats.
    private static func jsonValue(_ value: MessagePackValue) throws -> Any {
        switch value {
        case .nil: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .int(let value): return NSNumber(value: value)
        case .uint(let value): return NSNumber(value: value)
        case .float(let value): return NSNumber(value: Double(value))
        case .double(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .array(let values): return try values.map(jsonValue)
        case .map(let map):
            var object: [String: Any] = [:]
            for (key, value) in map {
                guard case .string(let name) = key else {
                    throw StateUpdateDecodingError.invalidPayload("A map key that is not a string.")
                }
                object[name] = try jsonValue(value)
            }
            return object
        case .binary, .extended:
            throw StateUpdateDecodingError.invalidPayload("A binary or extended value in a state update.")
        }
    }

    private func decode(payload: [Any], keyTable: (StateUpdateOpcode) -> DynamicKeyTable) throws -> DecodedStateUpdate {
        guard let first = payload.first, let opcodeValue = intValue(first),
              let opcode = StateUpdateOpcode(rawValue: opcodeValue) else {
            throw StateUpdateDecodingError.invalidPayload("Unknown state update opcode.")
        }
        
        // With the syncSequence feature, index 1 is the sync sequence (#332); otherwise every entry
        // after the opcode is a patch. The format follows the negotiation, never the shape.
        var syncSeq: UInt64?
        if syncSequence {
            guard payload.count > 1, let seq = SyncAckFrame.syncSequence(payload[1]) else {
                throw StateUpdateDecodingError.invalidPayload("Invalid sync sequence.")
            }
            syncSeq = seq
        }
        let patchStartIndex = syncSequence ? 2 : 1

        if opcode == .noChange && payload.count > patchStartIndex {
            throw StateUpdateDecodingError.invalidPayload("noChange payload must not include patches.")
        }

        if opcode == .resync {
            // A resync's snapshot holds every row again, as creates.
            rowTables.clear()
        }
        let patches = try decodePatches(from: payload.dropFirst(patchStartIndex), keyTable: keyTable(opcode))
        let update: StateUpdate

        switch opcode {
        case .noChange:
            update = .noChange
        case .firstSync:
            update = .firstSync(patches)
        case .diff:
            update = .diff(patches)
        case .resync:
            // Only a syncSequence session is ever sent one.
            guard syncSequence else {
                throw StateUpdateDecodingError.invalidPayload("Unknown state update opcode.")
            }
            update = .firstSync(patches)
        }

        // derived IDs are no longer in the payload
        return DecodedStateUpdate(update: update, landID: nil, playerID: nil, syncSeq: syncSeq, resync: opcode == .resync)
    }

    // decodeMetadata removed

    private func decodePatches(from payload: ArraySlice<Any>, keyTable: DynamicKeyTable) throws -> [StatePatch] {
        guard !payload.isEmpty else { return [] }

        var patches: [StatePatch] = []
        patches.reserveCapacity(payload.count)

        for entry in payload {
            guard let patchPayload = entry as? [Any], patchPayload.count >= 2 else {
                throw StateUpdateDecodingError.invalidPayload("Invalid patch entry.")
            }
            
            // Detect format: Legacy (path is String) vs PathHash (first element is number)
            let firstElement = patchPayload[0]
            let isPathHashFormat = firstElement is Int || firstElement is UInt32 || firstElement is NSNumber
            
            let path: String
            let opcodeIndex: Int
            
            if isPathHashFormat, let hasher = pathHasher {
                // PathHash format: [pathHash or path index, dynamicKey, op, value?]
                guard let pathID = uint32Value(firstElement) else {
                    throw StateUpdateDecodingError.invalidPayload("Invalid pathHash format.")
                }
                let pathHashValue: UInt32
                if pathIndex {
                    guard let hash = hasher.hash(atPathIndex: Int(pathID)) else {
                        throw StateUpdateDecodingError.invalidPayload("Unknown path index: \(pathID)")
                    }
                    pathHashValue = hash
                } else {
                    pathHashValue = pathID
                }
                
                // A row entry's second element is a slot or a slot list, not dynamic keys: the
                // op is read first.
                if patchPayload.count > 2, let opValue = Self.exactCount(patchPayload[2], upTo: Int(Int32.max)),
                   let rowOp = RowPatchOpcode(rawValue: opValue) {
                    patches.append(contentsOf: try decodeRowEntry(patchPayload, pathHash: pathHashValue, op: rowOp, hasher: hasher))
                    continue
                }

                let dynamicKeyRaw = patchPayload.count > 1 ? patchPayload[1] : nil
                let dynamicKeys = try decodeDynamicKeys(dynamicKeyRaw, keyTable: keyTable)

                // A merged entry: [parentId, dynamicKey, op, fieldMask, v1, v2, …].
                if patchPayload.count > 2, let opValue = intValue(patchPayload[2]),
                   let mergedOp = MergedPatchOpcode(rawValue: opValue) {
                    patches.append(contentsOf: try decodeMerged(
                        patchPayload, parentHash: pathHashValue, dynamicKeys: dynamicKeys, op: mergedOp, hasher: hasher
                    ))
                    continue
                }

                // Reconstruct path from hash + dynamic keys
                guard let pathPattern = hasher.getPath(for: pathHashValue) else {
                    throw StateUpdateDecodingError.invalidPayload("Unknown pathHash: \(pathHashValue)")
                }
                path = reconstructPath(from: pathPattern, dynamicKeys: dynamicKeys)
                opcodeIndex = 2
            } else {
                // Legacy format: [path, op, value?]
                guard let pathString = firstElement as? String else {
                    throw StateUpdateDecodingError.invalidPayload("Invalid patch path.")
                }
                path = pathString
                opcodeIndex = 1
            }
            
            guard patchPayload.count > opcodeIndex,
                  let opcodeValue = intValue(patchPayload[opcodeIndex]),
                  let opcode = StatePatchOpcode(rawValue: opcodeValue) else {
                throw StateUpdateDecodingError.invalidPayload("Unknown patch opcode.")
            }

            switch opcode {
            case .remove:
                if patchPayload.count > opcodeIndex + 1 {
                    throw StateUpdateDecodingError.invalidPayload("Remove patch must not include a value.")
                }
                patches.append(StatePatch(path: path, operation: .delete))
            case .set:
                let rawValue = try extractPatchValue(from: patchPayload, startIndex: opcodeIndex + 1)
                let value = try logicalValue(Self.snapshotValue(fromJSON: rawValue), path: path)
                patches.append(StatePatch(path: path, operation: .set(value)))
            case .add:
                let rawValue = try extractPatchValue(from: patchPayload, startIndex: opcodeIndex + 1)
                let value = try logicalValue(Self.snapshotValue(fromJSON: rawValue), path: path)
                patches.append(StatePatch(path: path, operation: .add(value)))
            }
        }

        return patches
    }
    
    /// A row entry's patches, at the paths today's entries would name: a create is the set of
    /// the row, a delete its removal, a column one set or removal per slot.
    ///
    /// Strict (a violation throws, and the frame's earlier row entries stay applied):
    /// - a create on a bound slot, or with a generation not above the slot's last one;
    /// - a delete or a column on an unbound slot;
    /// - a column whose slots are not ascending, or whose values are not one per slot.
    private func decodeRowEntry(_ entry: [Any], pathHash: UInt32, op: RowPatchOpcode, hasher: PathHasher) throws -> [StatePatch] {
        guard let pattern = hasher.getPath(for: pathHash) else {
            throw StateUpdateDecodingError.invalidPayload("Unknown pathHash: \(pathHash)")
        }
        // The table is the pattern up to its first dynamic key.
        let components = pattern.split(separator: ".", omittingEmptySubsequences: false)
        guard let keyAt = components.firstIndex(of: "*"),
              components[(keyAt + 1)...].allSatisfy({ $0 != "*" }),
              let table = hasher.pathHashes[components[...keyAt].joined(separator: ".")]
        else {
            throw StateUpdateDecodingError.invalidPayload("Row entry at \(pattern), which is not a row or a leaf of one.")
        }
        func slots() throws -> [Int] {
            guard let raw = entry[1] as? [Any] else {
                throw StateUpdateDecodingError.invalidPayload("Column entry without a slot list.")
            }
            let slots = raw.compactMap { Self.exactCount($0, upTo: Int(Int32.max)) }
            guard slots.count == raw.count, !slots.isEmpty, zip(slots, slots.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw StateUpdateDecodingError.invalidPayload("Column entry: slots are not ascending integers.")
            }
            return slots
        }
        func rowKey(_ slot: Int) throws -> String {
            guard let key = rowTables.key(table: table, slot: slot) else {
                throw StateUpdateDecodingError.invalidPayload("Row entry on unbound slot \(slot) of \(pattern).")
            }
            return key
        }
        switch op {
        case .create, .delete:
            guard pathHash == table, let slot = Self.exactCount(entry[1], upTo: Int(Int32.max)) else {
                throw StateUpdateDecodingError.invalidPayload("Row create or delete at \(pattern) without a slot.")
            }
            if op == .delete {
                guard entry.count == 3 else {
                    throw StateUpdateDecodingError.invalidPayload("Row delete must not include a value.")
                }
                let path = reconstructPath(from: pattern, dynamicKeys: [try rowKey(slot)])
                rowTables.unbind(table: table, slot: slot)
                return [StatePatch(path: path, operation: .delete)]
            }
            // [tableId, slot, 6, generation, parentSlot, key, value]
            guard entry.count == 7, let generation = Self.exactCount(entry[3], upTo: Int(UInt32.max)).map(UInt32.init), entry[4] is NSNull, let key = entry[5] as? String else {
                throw StateUpdateDecodingError.invalidPayload("Invalid row create entry.")
            }
            guard rowTables.key(table: table, slot: slot) == nil else {
                throw StateUpdateDecodingError.invalidPayload("Row create on bound slot \(slot) of \(pattern).")
            }
            if let last = rowTables.lastGeneration(table: table, slot: slot), generation <= last {
                throw StateUpdateDecodingError.invalidPayload("Row create on slot \(slot) of \(pattern): generation \(generation) after \(last).")
            }
            let path = reconstructPath(from: pattern, dynamicKeys: [key])
            let value = try logicalValue(Self.snapshotValue(fromJSON: entry[6]), path: path)
            rowTables.bind(table: table, slot: slot, key: key, generation: generation)
            return [StatePatch(path: path, operation: .set(value))]
        case .columnSet:
            guard pathHash != table, entry.count == 4, let values = entry[3] as? [Any] else {
                throw StateUpdateDecodingError.invalidPayload("Invalid column set entry.")
            }
            let slots = try slots()
            guard values.count == slots.count else {
                throw StateUpdateDecodingError.invalidPayload("Column set: \(slots.count) slots for \(values.count) values.")
            }
            return try zip(slots, values).map { slot, raw in
                let path = reconstructPath(from: pattern, dynamicKeys: [try rowKey(slot)])
                return StatePatch(path: path, operation: .set(try logicalValue(Self.snapshotValue(fromJSON: raw), path: path)))
            }
        case .columnClear:
            guard pathHash != table, entry.count == 3 else {
                throw StateUpdateDecodingError.invalidPayload("Invalid column clear entry.")
            }
            return try slots().map { slot in
                StatePatch(path: reconstructPath(from: pattern, dynamicKeys: [try rowKey(slot)]), operation: .delete)
            }
        }
    }

    /// A merged entry's patches, one per mask bit in ascending order.
    private func decodeMerged(
        _ entry: [Any],
        parentHash: UInt32,
        dynamicKeys: [String],
        op: MergedPatchOpcode,
        hasher: PathHasher
    ) throws -> [StatePatch] {
        guard entry.count > 3, let mask = uint32Value(entry[3]) else {
            throw StateUpdateDecodingError.invalidPayload("Merged entry without a field mask.")
        }
        let values = entry.dropFirst(4)
        guard mask != 0, mask.nonzeroBitCount == values.count else {
            throw StateUpdateDecodingError.invalidPayload("Merged entry: mask \(mask) for \(values.count) values.")
        }
        var patches: [StatePatch] = []
        var remaining = mask
        for raw in values {
            let bit = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            guard let childHash = fieldMerge?.childHash(parent: parentHash, bit: bit),
                  let pattern = hasher.getPath(for: childHash) else {
                throw StateUpdateDecodingError.invalidPayload("Unknown merged field: bit \(bit) of pathHash \(parentHash)")
            }
            let path = reconstructPath(from: pattern, dynamicKeys: dynamicKeys)
            let value = try logicalValue(Self.snapshotValue(fromJSON: raw), path: path)
            patches.append(StatePatch(path: path, operation: op == .set ? .set(value) : .add(value)))
        }
        return patches
    }

    /// Decode dynamic keys from raw format (supports slot, [slot, key], array of keys, or null)
    private func decodeDynamicKeys(_ raw: Any?, keyTable: DynamicKeyTable) throws -> [String] {
        // Treat nil and NSNull as empty list (no dynamic keys)
        // In PathHash mode, encoder emits null for patches with no dynamic keys
        guard let raw = raw, !(raw is NSNull) else {
            return []
        }
        
        // Single slot (Int) - lookup from table
        if let slot = intValue(raw) {
            if let key = keyTable.getKey(for: slot) {
                return [key]
            }
            throw StateUpdateDecodingError.invalidPayload("Dynamic key slot \(slot) used before definition")
        }
        
        // Single string key
        if let key = raw as? String {
            return [key]
        }
        
        // Definition: [slot, key] or array of keys
        if let array = raw as? [Any] {
            // Check if it's a definition: [number, string]
            if array.count == 2,
               let slot = intValue(array[0]),
               let key = array[1] as? String {
                keyTable.setKey(key, for: slot)
                return [key]
            }
            
            // Multi-key array: resolve each key
            var keys: [String] = []
            for item in array {
                if let slot = intValue(item) {
                    if let key = keyTable.getKey(for: slot) {
                        keys.append(key)
                    } else {
                        throw StateUpdateDecodingError.invalidPayload("Dynamic key slot \(slot) used before definition")
                    }
                } else if let key = item as? String {
                    keys.append(key)
                } else if let def = item as? [Any], def.count == 2,
                          let slot = intValue(def[0]),
                          let key = def[1] as? String {
                    keyTable.setKey(key, for: slot)
                    keys.append(key)
                } else {
                    throw StateUpdateDecodingError.invalidPayload("Invalid dynamic key format: \(item)")
                }
            }
            return keys
        }
        
        throw StateUpdateDecodingError.invalidPayload("Invalid dynamic key format: \(raw)")
    }
    
    /// Reconstruct JSON Pointer path from pattern and dynamic keys
    private func reconstructPath(from pattern: String, dynamicKeys: [String]) -> String {
        var components = pattern.split(separator: ".").map(String.init)
        var keyIndex = 0
        
        for i in 0..<components.count {
            if components[i] == "*" {
                if keyIndex < dynamicKeys.count {
                    components[i] = dynamicKeys[keyIndex]
                    keyIndex += 1
                }
            }
        }
        
        return "/" + components.joined(separator: "/")
    }

    /// Converts a `JSONSerialization` value to a `SnapshotValue` (#171).
    ///
    /// `JSONSerialization` returns JSON numbers and booleans as `NSNumber`, and an `NSNumber`
    /// holding 0 or 1 casts to `Bool`, so `SnapshotValue.make` would read a JSON 0 or 1 as a
    /// boolean. Here `JSONSerializationNumber` classifies them: only a JSON `true`/`false` is a
    /// boolean. Arrays and objects are converted element by element; anything else (strings,
    /// `NSNull`) goes through `SnapshotValue.make`.
    static func snapshotValue(fromJSON value: Any) throws -> SnapshotValue {
        if let number = JSONSerializationNumber(value) {
            switch number {
            case .bool(let bool): return .bool(bool)
            case .int(let int): return .int(int)
            case .unsigned(let unsigned): return try SnapshotValue.make(from: unsigned)
            case .double(let double): return .double(double)
            }
        }
        if let array = value as? [Any] {
            return .array(try array.map { try snapshotValue(fromJSON: $0) })
        }
        if let object = value as? [String: Any] {
            return .object(try object.mapValues { try snapshotValue(fromJSON: $0) })
        }
        return try SnapshotValue.make(from: value)
    }

    private func extractPatchValue(from payload: [Any], startIndex: Int) throws -> Any {
        guard payload.count > startIndex else {
            throw StateUpdateDecodingError.invalidPayload("Patch value is missing.")
        }
        if payload.count == startIndex + 1 {
            return payload[startIndex]
        }
        return Array(payload.dropFirst(startIndex))
    }
    
    private func uint32Value(_ value: Any) -> UInt32? {
        if let intValue = value as? Int {
            return UInt32(exactly: intValue)
        }
        if let uintValue = value as? UInt32 {
            return uintValue
        }
        if let number = value as? NSNumber {
            // Exact, as above: `uint32Value` would wrap a negative or oversized number.
            return UInt32(exactly: number.doubleValue)
        }
        return nil
    }

    /// A slot, a generation or a row op: a number that is an integer in `0...limit`, exactly.
    /// `intValue` truncates a fraction and takes a negative number or a boolean, any of which
    /// would address a row the sender didn't name.
    private static func exactCount(_ value: Any, upTo limit: Int) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        switch String(cString: number.objCType) {
        case "c", "B":
            // A boolean (JSON `true`, MessagePack `true`).
            return nil
        default:
            break
        }
        let double = number.doubleValue
        guard double == double.rounded(), double >= 0, double <= Double(limit) else { return nil }
        return number.intValue
    }

    private func intValue(_ value: Any) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
