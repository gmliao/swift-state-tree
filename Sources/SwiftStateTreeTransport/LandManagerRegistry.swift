import Foundation
import SwiftStateTree

/// Registry for managing multiple LandManagers (for distributed systems).
///
/// In single-process mode, this wraps a single LandManager.
/// In multi-process mode, this aggregates multiple distributed LandManagers.
///
/// Used by LandRouter for multi-room routing and land creation.
public protocol LandManagerRegistry: Actor {
    associatedtype State: StateNodeProtocol
    
    /// Query all lands across all registered LandManagers.
    ///
    /// - Returns: Array of all land IDs from all registered LandManagers.
    func listAllLands() async -> [LandID]
    
    /// Get stats for a land (may be on any LandManager).
    ///
    /// - Parameter landID: The unique identifier for the land.
    /// - Returns: LandStats if the land exists, nil otherwise.
    func getLandStats(landID: LandID) async -> LandStats?
    
    /// Request creation of a new land on a suitable LandManager.
    ///
    /// The registry decides which LandManager should create the land.
    /// In single-process mode, this is the single LandManager.
    /// In multi-process mode, this could use load balancing or other strategies.
    ///
    /// - Parameters:
    ///   - landID: The unique identifier for the land.
    ///   - definition: The Land definition to use.
    ///   - initialState: The initial state for the land.
    /// - Returns: The LandContainer for the created land (internal implementation detail).
    func createLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State,
        metadata: [String: String]
    ) async -> LandContainer<State>
    
    /// Get a specific land (may be on any LandManager).
    ///
    /// - Parameter landID: The unique identifier for the land.
    /// - Returns: The LandContainer if the land exists, nil otherwise (internal implementation detail).
    func getLand(landID: LandID) async -> LandContainer<State>?
}

/// Single-process implementation (wraps one LandManager).
///
/// This is the current implementation for single-process mode.
/// It simply delegates all operations to a single LandManager.
public actor SingleLandManagerRegistry<State: StateNodeProtocol>: LandManagerRegistry {
    private let landManager: LandManager<State>
    
    /// Initialize a SingleLandManagerRegistry.
    ///
    /// - Parameter landManager: The single LandManager to wrap.
    public init(landManager: LandManager<State>) {
        self.landManager = landManager
    }
    
    public func listAllLands() async -> [LandID] {
        await landManager.listLands()
    }
    
    public func getLandStats(landID: LandID) async -> LandStats? {
        await landManager.getLandStats(landID: landID)
    }
    
    public func createLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State,
        metadata: [String: String]
    ) async -> LandContainer<State> {
        await landManager.getOrCreateLand(
            landID: landID,
            definition: definition,
            initialState: initialState,
            metadata: metadata
        )
    }
    
    public func getLand(landID: LandID) async -> LandContainer<State>? {
        await landManager.getLand(landID: landID)
    }
}

/// Multi-process implementation (aggregates multiple distributed LandManagers).
///
/// Future: This would use distributed actors to aggregate multiple LandManagers
/// across different processes/servers.
///
/// For now, this is a placeholder that can be implemented when distributed
/// actors are added to the system.
public actor DistributedLandManagerRegistry<State: StateNodeProtocol>: LandManagerRegistry {
    // Future: List of distributed LandManager references
    // private var landManagers: [any LandManagerProtocol<State>] = []
    
    /// Initialize a DistributedLandManagerRegistry.
    ///
    /// Future: This would accept a list of distributed LandManager references.
    public init() {
        // Future: Initialize with distributed LandManagers
    }
    
    public func listAllLands() async -> [LandID] {
        // Future: Query all distributed LandManagers
        return []
    }
    
    public func getLandStats(landID: LandID) async -> LandStats? {
        // Future: Query the appropriate distributed LandManager
        return nil
    }
    
    public func createLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State,
        metadata: [String: String]
    ) async -> LandContainer<State> {
        // Future: Select a suitable distributed LandManager and create land there
        fatalError("DistributedLandManagerRegistry not yet implemented")
    }
    
    public func getLand(landID: LandID) async -> LandContainer<State>? {
        // Future: Query the appropriate distributed LandManager
        return nil
    }
}

