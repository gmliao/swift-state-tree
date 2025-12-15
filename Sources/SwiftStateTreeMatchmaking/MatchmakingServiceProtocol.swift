import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Protocol abstraction for MatchmakingService operations.
///
/// This protocol allows MatchmakingService to be abstracted for future distributed actor support.
/// All method parameters and return values must be Sendable and Codable to support
/// serialization across process boundaries.
///
/// This protocol enables:
/// - Easy replacement with distributed actor implementations in the future
/// - Testing with mock implementations
/// - Dependency injection and loose coupling
public protocol MatchmakingServiceProtocol: Actor {
    associatedtype State: StateNodeProtocol
    
    /// Request matchmaking for a user/player.
    ///
    /// - Parameters:
    ///   - playerID: The user/player requesting matchmaking.
    ///   - preferences: Matchmaking preferences (includes landType).
    /// - Returns: MatchmakingResult indicating success, queued, or failure.
    func matchmake(
        playerID: PlayerID,
        preferences: MatchmakingPreferences
    ) async throws -> MatchmakingResult
    
    /// Cancel matchmaking request for a user/player.
    ///
    /// - Parameter playerID: The user/player to cancel matchmaking for.
    func cancelMatchmaking(playerID: PlayerID) async
    
    /// Get matchmaking status for a user/player.
    ///
    /// - Parameter playerID: The user/player to get status for.
    /// - Returns: MatchmakingStatus if player is in queue, nil otherwise.
    func getStatus(playerID: PlayerID) async -> MatchmakingStatus?
}

