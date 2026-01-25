import Foundation
import SwiftStateTree

/// Decoded state update payload with optional routing metadata.
public struct DecodedStateUpdate: Sendable {
    public let update: StateUpdate
    public let landID: String?
    public let playerID: PlayerID?

    public init(update: StateUpdate, landID: String? = nil, playerID: PlayerID? = nil) {
        self.update = update
        self.landID = landID
        self.playerID = playerID
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
        return DecodedStateUpdate(update: update)
    }
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

    public init(pathHasher: PathHasher? = nil) {
        self.pathHasher = pathHasher
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
        
        let patchStartIndex = 1

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
        return DecodedStateUpdate(update: update, landID: nil, playerID: nil)
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
                // PathHash format: [pathHash, dynamicKey, op, value?]
                guard let pathHashValue = uint32Value(firstElement) else {
                    throw StateUpdateDecodingError.invalidPayload("Invalid pathHash format.")
                }
                
                let dynamicKeyRaw = patchPayload.count > 1 ? patchPayload[1] : nil
                let dynamicKeys = try decodeDynamicKeys(dynamicKeyRaw, keyTable: keyTable)
                
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
                let value = try SnapshotValue.make(from: rawValue)
                patches.append(StatePatch(path: path, operation: .set(value)))
            case .add:
                let rawValue = try extractPatchValue(from: patchPayload, startIndex: opcodeIndex + 1)
                let value = try SnapshotValue.make(from: rawValue)
                patches.append(StatePatch(path: path, operation: .add(value)))
            }
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
