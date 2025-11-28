import Foundation

// MARK: - Join Decision

/// Decision returned by the CanJoin handler.
///
/// The CanJoin handler validates whether a player should be allowed to join the Land.
/// It can either allow the join (with a specific PlayerID) or deny it.
public enum JoinDecision: Sendable {
    /// Allow the player to join with the specified PlayerID.
    case allow(playerID: PlayerID)
    /// Deny the join request with an optional reason.
    case deny(reason: String?)
}

// MARK: - Player Session

/// Session information for join requests.
///
/// Contains metadata about the joining player that can be used in the CanJoin handler
/// to make validation decisions (e.g., checking user level, team status, etc.).
public struct PlayerSession: Sendable {
    /// The user's unique identifier (e.g., account ID).
    public let userID: String
    /// Optional device identifier.
    public let deviceID: String?
    /// Additional metadata that can be used for validation.
    public let metadata: [String: String]
    
    public init(
        userID: String,
        deviceID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.metadata = metadata
    }
}

// MARK: - Join Errors

/// Errors that can be thrown during join validation in the CanJoin handler.
public enum JoinError: Error, Sendable {
    /// The room has reached its maximum player capacity.
    case roomIsFull
    /// The player's level is below the required minimum.
    case levelTooLow(required: Int)
    /// The player is banned from this Land.
    case banned
    /// A custom error with a specific message.
    case custom(String)
}
