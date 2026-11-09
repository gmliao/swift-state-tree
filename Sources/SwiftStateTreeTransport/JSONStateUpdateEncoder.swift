import Foundation
import SwiftStateTree

/// JSON object-based state update encoder.
public struct JSONStateUpdateEncoder: SyncSequencedStateUpdateEncoder {
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

    public func encode(
        update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope
    ) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID)
    }

    public func encode(
        update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope,
        syncSeq: UInt64?
    ) throws -> Data {
        guard let syncSeq else { return try encode(update: update, landID: landID, playerID: playerID) }
        return try encoder.encode(SequencedStateUpdate(update: update, seq: syncSeq))
    }
}

/// `StateUpdate`'s JSON object with the sync sequence: `{"type":…, "seq":N, "patches":[…]}`.
private struct SequencedStateUpdate: Encodable {
    let update: StateUpdate
    let seq: UInt64

    private enum CodingKeys: String, CodingKey {
        case type, seq, patches
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(update.updateType, forKey: .type)
        try container.encode(seq, forKey: .seq)
        switch update {
        case .noChange: break
        case .firstSync(let patches), .diff(let patches):
            try container.encode(patches, forKey: .patches)
        }
    }
}
