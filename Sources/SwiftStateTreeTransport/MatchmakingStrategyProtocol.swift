import Foundation
import SwiftStateTree

/// Preferences for matchmaking.
///
/// Defines the criteria for matching users/players together.
///
/// **Note**: This type is defined in `SwiftStateTreeTransport` because it's used by
/// `MatchmakingStrategy` protocol, which is used by `LandTypeRegistry`.
public struct MatchmakingPreferences: Codable, Sendable {
    /// Land type identifier (e.g., "collaboration-room", "chat-channel", "battle-royale").
    /// This should match the LandDefinition.id of the land type.
    public let landType: String
    
    /// Minimum user level (optional).
    public let minLevel: Int?
    
    /// Maximum user level (optional).
    public let maxLevel: Int?
    
    /// Region identifier (optional).
    public let region: String?
    
    /// Maximum wait time in seconds (optional).
    public let maxWaitTime: TimeInterval?
    
    public init(
        landType: String,
        minLevel: Int? = nil,
        maxLevel: Int? = nil,
        region: String? = nil,
        maxWaitTime: TimeInterval? = nil
    ) {
        self.landType = landType
        self.minLevel = minLevel
        self.maxLevel = maxLevel
        self.region = region
        self.maxWaitTime = maxWaitTime
    }
}

/// Strategy for determining how players are matched together.
///
/// Allows customization of matchmaking logic without modifying MatchmakingService.
/// Users can implement custom strategies for different game types or requirements.
///
/// **Note**: This protocol is defined in `SwiftStateTreeTransport` because it's used by
/// `LandTypeRegistry`, which is a core transport component. The default implementation
/// (`DefaultMatchmakingStrategy`) is in `SwiftStateTreeMatchmaking`.
public protocol MatchmakingStrategy: Sendable {
    /// Check if a player can be matched with a land.
    ///
    /// - Parameters:
    ///   - playerPreferences: The player's matchmaking preferences.
    ///   - landStats: Statistics of the land to check.
    ///   - waitingPlayers: Other players currently in queue.
    /// - Returns: True if the player can be matched to this land.
    func canMatch(
        playerPreferences: MatchmakingPreferences,
        landStats: LandStats,
        waitingPlayers: [MatchmakingRequest]
    ) async -> Bool
    
    /// Determine if enough players are available to start a match.
    ///
    /// - Parameters:
    ///   - matchingPlayers: Players with compatible preferences.
    ///   - preferences: The matchmaking preferences.
    /// - Returns: True if there are enough players to start a match.
    func hasEnoughPlayers(
        matchingPlayers: [MatchmakingRequest],
        preferences: MatchmakingPreferences
    ) -> Bool
}

/// Internal structure for matchmaking requests (used by strategy).
///
/// **Note**: This type is defined in `SwiftStateTreeTransport` because it's used by
/// `MatchmakingStrategy` protocol, which is used by `LandTypeRegistry`.
public struct MatchmakingRequest: Sendable {
    public let playerID: PlayerID
    public let preferences: MatchmakingPreferences
    public let queuedAt: Date
    
    public init(playerID: PlayerID, preferences: MatchmakingPreferences, queuedAt: Date) {
        self.playerID = playerID
        self.preferences = preferences
        self.queuedAt = queuedAt
    }
}


