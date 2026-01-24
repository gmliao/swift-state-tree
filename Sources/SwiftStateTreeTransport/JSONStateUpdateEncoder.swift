import Foundation
import SwiftStateTree

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
    
    public func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        // JSON encoder doesn't use playerSlot, just use playerID
        try encode(update: update, landID: landID, playerID: playerID)
    }
}
