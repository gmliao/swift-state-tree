import Foundation
import SwiftStateTree

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
