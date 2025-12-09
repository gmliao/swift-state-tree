import Foundation
import SwiftStateTree

/// Preferences for matchmaking.
///
/// Defines the criteria for matching users/players together.
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

/// Result of a matchmaking request.
public enum MatchmakingResult: Codable, Sendable {
    /// Successfully matched to a land.
    case matched(landID: LandID)
    
    /// Queued for matching (with position in queue).
    case queued(position: Int)
    
    /// Matchmaking failed with reason.
    case failed(reason: String)
}

/// Status of an ongoing matchmaking request.
public struct MatchmakingStatus: Codable, Sendable {
    /// Current position in queue.
    public let position: Int
    
    /// Time spent in queue (seconds).
    public let waitTime: TimeInterval
    
    /// Preferences used for this matchmaking.
    public let preferences: MatchmakingPreferences
    
    public init(
        position: Int,
        waitTime: TimeInterval,
        preferences: MatchmakingPreferences
    ) {
        self.position = position
        self.waitTime = waitTime
        self.preferences = preferences
    }
}

