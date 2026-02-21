import Foundation

/// Errors that can occur when resolving or loading reevaluation replay sessions.
public enum ReevaluationReplayError: Error, Sendable {
    /// Replay session descriptor (instanceId) is invalid or cannot be decoded.
    case invalidSessionDescriptor(String)
}
