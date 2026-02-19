public enum ReevaluationReplayEventPolicy: String, Codable, Sendable {
    case projectedOnly
    case projectedWithFallback
}

public struct ReevaluationReplayPolicyService: Sendable {
    public let eventPolicy: ReevaluationReplayEventPolicy

    public init(eventPolicy: ReevaluationReplayEventPolicy) {
        self.eventPolicy = eventPolicy
    }
}
