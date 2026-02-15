import Foundation
import SwiftStateTree

public enum ReevaluationReplayProjectorRegistry {
    public static func defaultResolver(for landType: String) -> (any ReevaluationReplayProjecting)? {
        switch landType {
        case "hero-defense":
            return HeroDefenseReplayProjector()
        default:
            return nil
        }
    }
}

public struct HeroDefenseReplayProjector: ReevaluationReplayProjecting {
    private static let allowedStateKeys: Set<String> = [
        "players",
        "monsters",
        "turrets",
        "base",
        "score",
    ]

    public init() {}

    public func project(_ result: ReevaluationStepResult) throws -> ProjectedReplayFrame {
        let projectedState = try parseProjectedState(from: result.actualState)
        return ProjectedReplayFrame(
            tickID: result.tickId,
            stateObject: projectedState,
            serverEvents: []
        )
    }

    private func parseProjectedState(from actualState: AnyCodable?) throws -> [String: AnyCodable] {
        guard let jsonText = actualState?.base as? String else {
            return [:]
        }

        let jsonData = Data(jsonText.utf8)
        let rawJSON = try JSONSerialization.jsonObject(with: jsonData)
        guard let jsonObject = rawJSON as? [String: Any] else {
            return [:]
        }

        var projected: [String: AnyCodable] = [:]
        for key in Self.allowedStateKeys where jsonObject[key] != nil {
            projected[key] = AnyCodable(jsonObject[key])
        }
        return projected
    }
}
