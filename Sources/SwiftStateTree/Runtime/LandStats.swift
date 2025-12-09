import Foundation

/// Statistics for a Land instance.
///
/// Provides information about the current state of a land, including
/// player count, creation time, and last activity time.
public struct LandStats: Codable, Sendable {
    /// The unique identifier for the land.
    public let landID: LandID
    
    /// Current number of players in the land.
    public let playerCount: Int
    
    /// Timestamp when the land was created.
    public let createdAt: Date
    
    /// Timestamp of the last activity in the land.
    public let lastActivityAt: Date
    
    public init(
        landID: LandID,
        playerCount: Int,
        createdAt: Date,
        lastActivityAt: Date
    ) {
        self.landID = landID
        self.playerCount = playerCount
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}

