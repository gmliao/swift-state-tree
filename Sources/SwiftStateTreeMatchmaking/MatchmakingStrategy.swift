import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

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


