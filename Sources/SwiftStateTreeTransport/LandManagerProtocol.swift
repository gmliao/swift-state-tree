import Foundation
import SwiftStateTree

/// Protocol abstraction for LandManager operations.
///
/// This protocol allows LandManager to be abstracted for future distributed actor support.
/// MatchmakingService should depend on this protocol rather than the concrete LandManager implementation,
/// making it easy to replace with a distributed actor in the future.
///
/// All method parameters and return values must be Sendable and Codable to support
/// serialization across process boundaries.
public protocol LandManagerProtocol: Actor {
    associatedtype State: StateNodeProtocol
    
    /// Get or create a land with the specified ID.
    ///
    /// - Parameters:
    ///   - landID: The unique identifier for the land.
    ///   - definition: The Land definition to use if creating a new land.
    ///   - initialState: The initial state for the land if creating a new one.
    /// - Returns: The LandContainer for the land.
    func getOrCreateLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State
    ) async -> LandContainer<State>
    
    /// Get an existing land by ID.
    ///
    /// - Parameter landID: The unique identifier for the land.
    /// - Returns: The LandContainer if the land exists, nil otherwise.
    func getLand(landID: LandID) async -> LandContainer<State>?
    
    /// Remove a land from the manager.
    ///
    /// - Parameter landID: The unique identifier for the land to remove.
    func removeLand(landID: LandID) async
    
    /// List all active land IDs.
    ///
    /// - Returns: An array of all active land IDs.
    func listLands() async -> [LandID]
    
    /// Get statistics for a specific land.
    ///
    /// - Parameter landID: The unique identifier for the land.
    /// - Returns: LandStats if the land exists, nil otherwise.
    func getLandStats(landID: LandID) async -> LandStats?
}

