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

// MARK: - Placeholder: returns empty Lifetime tick; replaced with real reevaluation logic in Task 3

internal func StandardReplayLifetime<State: StateNodeProtocol>(
    landType _: String
) -> LifetimeNode<State> {
    Lifetime { _ in }
}

// MARK: - GenericReplayLand

/// Zero-config generic replay land for any State conforming to StateNodeProtocol & Decodable.
///
/// Replaces hand-written game-specific replay lands (e.g. HeroDefenseReplayLand).
/// - Starts reevaluation verification automatically on first tick.
/// - Decodes projected state from `result.actualState` using JSONDecoder.
/// - Forwards ALL recorded server events without filtering.
/// - Emits ReplayTickEvent after each result.
///
/// For custom actions (fast-forward, reset, etc.), use
/// `StandardReplayLifetime` and `StandardReplayServerEvents` instead.
public enum GenericReplayLand {
    /// Creates a generic replay LandDefinition.
    ///
    /// - Parameters:
    ///   - landType: The BASE land type (e.g. "hero-defense"), NOT the replay land type.
    ///     The returned definition's ID will be "\(landType)-replay".
    ///   - stateType: The State type. Must conform to `StateNodeProtocol`. For actual state
    ///     decoding in Task 3, the state must also be `Decodable`.
    public static func makeLand<State: StateNodeProtocol>(
        landType: String,
        stateType: State.Type
    ) -> LandDefinition<State> {
        Land("\(landType)-replay", using: stateType) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(64)
            }

            StandardReplayLifetime(landType: landType) as LifetimeNode<State>

            ServerEvents {
                Register(ReplayTickEvent.self)
            }
        }
    }
}
