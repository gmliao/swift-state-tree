import Foundation
import SwiftStateTree

/// Decoded state update payload with optional routing metadata.
public struct DecodedStateUpdate: Sendable {
    public let update: StateUpdate
    public let landID: String?
    public let playerID: PlayerID?
    /// The land's sync sequence the frame carried (#332), or nil for a frame without one.
    public let syncSeq: UInt64?

    public init(update: StateUpdate, landID: String? = nil, playerID: PlayerID? = nil, syncSeq: UInt64? = nil) {
        self.update = update
        self.landID = landID
        self.playerID = playerID
        self.syncSeq = syncSeq
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
        let update = try decoder.decode(StateUpdate.self, from: data)
        let seq = try decoder.decode(SyncSeqField.self, from: data).seq
        return DecodedStateUpdate(update: update, syncSeq: seq)
    }
}

/// The JSON object's optional `seq` key.
private struct SyncSeqField: Decodable {
    let seq: UInt64?
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
    }
    
    private let keyTableStore = DynamicKeyTableStore()

    /// The state's atomic values: a positional value at an atomic path is rebuilt keyed. `nil`
    /// leaves values as they arrive (a keyed server, or a caller that wants the wire form).
    private let atomicLayout: AtomicLayoutTable?

    /// Path ids are path indices (the encoder's `pathIndex`), not hashes.
    private let pathIndex: Bool

    /// The parents' fields by bit, for merged entries (`MergedPatchOpcode`).
    private let fieldMerge: FieldMergeTable?

    public init(pathHasher: PathHasher? = nil, atomicLayout: AtomicLayoutTable? = nil, pathIndex: Bool = false) {
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
        guard let opcodeValue = intValue(payload[0]),
              let opcode = StateUpdateOpcode(rawValue: opcodeValue) else {
            throw StateUpdateDecodingError.invalidPayload("Unknown state update opcode.")
        }
        
        // A scalar after the opcode is the sync sequence (#332); patches are always arrays.
        var syncSeq: UInt64?
        if payload.count > 1, !(payload[1] is [Any]) {
            guard let number = payload[1] as? NSNumber else {
                throw StateUpdateDecodingError.invalidPayload("Invalid sync sequence.")
            }
            syncSeq = number.uint64Value
        }
        let patchStartIndex = syncSeq == nil ? 1 : 2

        if opcode == .noChange && payload.count > patchStartIndex {
            throw StateUpdateDecodingError.invalidPayload("noChange payload must not include patches.")
        }

        let patches = try decodePatches(from: payload.dropFirst(patchStartIndex))
        let update: StateUpdate

        switch opcode {
        case .noChange:
            update = .noChange
        case .firstSync:
            update = .firstSync(patches)
        case .diff:
            update = .diff(patches)
        }

        // derived IDs are no longer in the payload
        return DecodedStateUpdate(update: update, landID: nil, playerID: nil, syncSeq: syncSeq)
    }

    // decodeMetadata removed

    private func decodePatches(from payload: ArraySlice<Any>) throws -> [StatePatch] {
        guard !payload.isEmpty else { return [] }

        var patches: [StatePatch] = []
        patches.reserveCapacity(payload.count)
        
        // Use a dummy scope for key table (decoder doesn't have landID/playerID context)
        let keyTable = keyTableStore.table(for: nil, playerID: nil)

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
            return UInt32(intValue)
        }
        if let uintValue = value as? UInt32 {
            return uintValue
        }
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        return nil
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
