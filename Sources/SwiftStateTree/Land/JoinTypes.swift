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
    /// The player's unique identifier (typically derived from account/user ID).
    /// This will be converted to `PlayerID` in the `CanJoin` handler.
    public let playerID: String
    /// Optional device identifier.
    public let deviceID: String?
    /// Whether this is a guest session (not authenticated via JWT).
    public let isGuest: Bool
    /// Additional metadata that can be used for validation.
    public let metadata: [String: String]
    
    public init(
        playerID: String,
        deviceID: String? = nil,
        isGuest: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.playerID = playerID
        self.deviceID = deviceID
        self.isGuest = isGuest
        // Automatically add isGuest flag to metadata when isGuest is true
        var finalMetadata = metadata
        if isGuest {
            finalMetadata["isGuest"] = "true"
        }
        self.metadata = finalMetadata
    }
}

// MARK: - Join Errors

/// Errors a join can fail with: thrown by the CanJoin handler to refuse it (`roomIsFull`,
/// `levelTooLow`, `banned`, `custom`), or by the keeper (`landShuttingDown`, `superseded`).
public enum JoinError: Error, Sendable {
    /// The room has reached its maximum player capacity.
    case roomIsFull
    /// The player's level is below the required minimum.
    case levelTooLow(required: Int)
    /// The player is banned from this Land.
    case banned
    /// A custom error with a specific message.
    case custom(String)
    /// The Land is shutting down (it became empty and is being destroyed). Retry the join:
    /// `LandManager.getOrCreateLand` creates a fresh instance for the same ID.
    case landShuttingDown
    /// A newer join of the same player took the player first (#860). Two stages refuse a join
    /// this way:
    /// - **Its OnJoin was pending:** the join's entry was replaced by a newer join, or removed
    ///   by a leave, before its OnJoin input was appended. Its OnJoin input and the OnLeave of
    ///   the leave that removed the entry are both dropped. Its OnJoin resolvers ran, so
    ///   whatever they did outside the land is not undone.
    /// - **At its kick:** the join kicked the player's old session, and a later join of the
    ///   player arrived while the kick's leave ran (the fence, #940). The join inserted nothing
    ///   and ran no OnJoin resolver. The later join keeps the player; if that join fails or is
    ///   cancelled afterwards, the player is left with no entry, since this join already has its
    ///   answer.
    ///
    /// Through the router, the session gets `JOIN_DENIED` as its last frame, then the 4017
    /// `superseded` close.
    case superseded
}
