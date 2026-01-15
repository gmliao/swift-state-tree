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

    public init() {}

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

        for entry in payload {
            guard let patchPayload = entry as? [Any], patchPayload.count >= 2 else {
                throw StateUpdateDecodingError.invalidPayload("Invalid patch entry.")
            }
            guard let path = patchPayload[0] as? String else {
                throw StateUpdateDecodingError.invalidPayload("Invalid patch path.")
            }
            guard let opcodeValue = intValue(patchPayload[1]),
                  let opcode = StatePatchOpcode(rawValue: opcodeValue) else {
                throw StateUpdateDecodingError.invalidPayload("Unknown patch opcode.")
            }

            switch opcode {
            case .remove:
                if patchPayload.count > 2 {
                    throw StateUpdateDecodingError.invalidPayload("Remove patch must not include a value.")
                }
                patches.append(StatePatch(path: path, operation: .delete))
            case .set:
                let rawValue = try extractPatchValue(from: patchPayload)
                let value = try SnapshotValue.make(from: rawValue)
                patches.append(StatePatch(path: path, operation: .set(value)))
            case .add:
                let rawValue = try extractPatchValue(from: patchPayload)
                let value = try SnapshotValue.make(from: rawValue)
                patches.append(StatePatch(path: path, operation: .add(value)))
            }
        }

        return patches
    }

    private func extractPatchValue(from payload: [Any]) throws -> Any {
        guard payload.count >= 3 else {
            throw StateUpdateDecodingError.invalidPayload("Patch value is missing.")
        }
        if payload.count == 3 {
            return payload[2]
        }
        return Array(payload.dropFirst(2))
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
