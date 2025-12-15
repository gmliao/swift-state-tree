import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

// Note: MatchmakingStrategy protocol, MatchmakingPreferences, and MatchmakingRequest
// are all in SwiftStateTreeTransport because they're used by LandTypeRegistry

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

