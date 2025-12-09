import Foundation
import SwiftStateTree

/// Strategy for determining how players are matched together.
///
/// Allows customization of matchmaking logic without modifying MatchmakingService.
/// Users can implement custom strategies for different game types or requirements.
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

/// Default matchmaking strategy: simple "full then next" logic.
///
/// - If a land has space, match players to it
/// - If a land is full, try the next one
/// - Requires at least minPlayersToStart players with same landType to start a match
public struct DefaultMatchmakingStrategy: MatchmakingStrategy {
    /// Maximum players per land.
    public let maxPlayersPerLand: Int
    
    /// Minimum players required to start a match.
    public let minPlayersToStart: Int
    
    /// Initialize default strategy.
    ///
    /// - Parameters:
    ///   - maxPlayersPerLand: Maximum players allowed in a single land (default: 10).
    ///   - minPlayersToStart: Minimum players required to start a match (default: 1).
    public init(maxPlayersPerLand: Int = 10, minPlayersToStart: Int = 1) {
        self.maxPlayersPerLand = maxPlayersPerLand
        self.minPlayersToStart = minPlayersToStart
    }
    
    public func canMatch(
        playerPreferences: MatchmakingPreferences,
        landStats: LandStats,
        waitingPlayers: [MatchmakingRequest]
    ) async -> Bool {
        // Simple strategy: if land has space, can match
        // If full, try next land (return false to continue searching)
        return landStats.playerCount < maxPlayersPerLand
    }
    
    public func hasEnoughPlayers(
        matchingPlayers: [MatchmakingRequest],
        preferences: MatchmakingPreferences
    ) -> Bool {
        // Simple strategy: need at least minPlayersToStart players with same landType
        let sameLandType = matchingPlayers.filter { request in
            request.preferences.landType == preferences.landType
        }
        return sameLandType.count >= minPlayersToStart
    }
}


