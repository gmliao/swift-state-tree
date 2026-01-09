import Foundation
import SwiftStateTree

/// Supported encodings for state update payloads.
public enum StateUpdateEncoding: String, Sendable {
    case jsonObject
    case opcodeJsonArray
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
}

/// Opcode + JSON array state update encoder.
///
/// Format: [updateOpcode, playerID, patch...]
/// Patch format: [path, op, value?]
public struct OpcodeJSONStateUpdateEncoder: StateUpdateEncoder {
    public let encoding: StateUpdateEncoding = .opcodeJsonArray

    /// Per-instance JSONEncoder for encoding operations.
    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
    }

    public func encode(update: StateUpdate, landID _: String, playerID: PlayerID) throws -> Data {
        let opcode: StateUpdateOpcode
        let patches: [StatePatch]

        switch update {
        case .noChange:
            opcode = .noChange
            patches = []
        case .firstSync(let diffPatches):
            opcode = .firstSync
            patches = diffPatches
        case .diff(let diffPatches):
            opcode = .diff
            patches = diffPatches
        }

        var payload: [AnyCodable] = [
            AnyCodable(opcode.rawValue),
            AnyCodable(playerID.rawValue)
        ]

        for patch in patches {
            payload.append(AnyCodable(encodePatch(patch)))
        }

        return try encoder.encode(payload)
    }

    private func encodePatch(_ patch: StatePatch) -> [AnyCodable] {
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
}
