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
        let projectedServerEvents: [AnyCodable] = result.emittedServerEvents.map { event in
            AnyCodable([
                "typeIdentifier": event.typeIdentifier,
                "payload": event.payload,
            ])
        }
        return ProjectedReplayFrame(
            tickID: result.tickId,
            stateObject: projectedState,
            serverEvents: projectedServerEvents
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

        let sourceObject: [String: Any]
        if let values = jsonObject["values"] as? [String: Any] {
            sourceObject = values
        } else {
            sourceObject = jsonObject
        }

        var projected: [String: AnyCodable] = [:]
        for key in Self.allowedStateKeys {
            guard let value = sourceObject[key] else {
                continue
            }
            guard let sanitized = sanitizeStateValue(for: key, value: value) else {
                continue
            }
            projected[key] = AnyCodable(sanitized)
        }
        return projected
    }

    private func sanitizeStateValue(for key: String, value: Any) -> Any? {
        switch key {
        case "players", "monsters", "turrets":
            return sanitizeEntityCollection(value)
        case "base":
            if hasLegacyWrapperArtifact(value) {
                return nil
            }
            return value
        default:
            return value
        }
    }

    private func sanitizeEntityCollection(_ value: Any) -> [String: Any]? {
        guard let entities = value as? [String: Any] else {
            return nil
        }

        var sanitized: [String: Any] = [:]
        sanitized.reserveCapacity(entities.count)

        for (entityID, entityValue) in entities {
            if hasLegacyWrapperArtifact(entityValue) {
                continue
            }
            sanitized[entityID] = entityValue
        }

        return sanitized
    }

    private func hasLegacyWrapperArtifact(_ value: Any) -> Bool {
        guard let object = value as? [String: Any] else {
            return false
        }

        return object["base"] != nil
    }
}
