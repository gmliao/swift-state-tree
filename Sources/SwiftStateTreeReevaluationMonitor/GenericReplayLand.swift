import Foundation
import SwiftStateTree

// MARK: - ReplayTickEvent

/// Generic replay tick result event emitted by GenericReplayLand on each processed tick.
/// Replaces game-specific tick events (e.g. HeroDefenseReplayTickEvent).
@Payload
public struct ReplayTickEvent: ServerEventPayload {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(tickId: Int64, isMatch: Bool, expectedHash: String, actualHash: String) {
        self.tickId = tickId
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

// MARK: - Internal state decode helper

/// Decodes a State from `result.actualState`.
///
/// `actualState?.base` is a JSON string. It may be a flat JSON object or wrapped in
/// `{"values": {...}}` (SwiftStateTree serialization artifact). Both formats are tried.
func decodeReplayState<State: Decodable>(_ type: State.Type, from actualState: AnyCodable?) -> State? {
    guard let jsonText = actualState?.base as? String,
          let data = jsonText.data(using: .utf8)
    else { return nil }

    // Try direct decode first (flat format)
    if let decoded = try? JSONDecoder().decode(type, from: data) {
        return decoded
    }

    // Try "values" wrapper format: {"values": {...}}
    guard let rawJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let valuesRaw = rawJSON["values"],
          JSONSerialization.isValidJSONObject(valuesRaw),
          let valuesData = try? JSONSerialization.data(withJSONObject: valuesRaw),
          let decoded = try? JSONDecoder().decode(type, from: valuesData)
    else { return nil }

    return decoded
}
