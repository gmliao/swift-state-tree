import Foundation
import SwiftStateTree

/// Registry for land types.
///
/// Maps each landType to:
/// - LandDefinition factory (how to create the land)
/// - Initial state factory (how to create initial state)
/// - Matchmaking strategy (how to match users/players)
///
/// Each land type can have its own independent configuration, allowing different
/// matching rules, capacity limits, and behaviors for different types of lands.
public struct LandTypeRegistry<State: StateNodeProtocol>: Sendable {
    /// Factory: (landType, landID) -> LandDefinition
    /// The LandDefinition.id must match the landType.
    public let landFactory: @Sendable (String, LandID) -> LandDefinition<State>
    
    /// Factory: (landType, landID) -> State
    public let initialStateFactory: @Sendable (String, LandID) -> State
    
    /// Factory: landType -> MatchmakingStrategy
    /// Each land type can have its own matching rules.
    public let strategyFactory: @Sendable (String) -> any MatchmakingStrategy
    
    /// Initialize a LandTypeRegistry.
    ///
    /// - Parameters:
    ///   - landFactory: Factory function that creates a LandDefinition for a given landType and landID.
    ///     The returned LandDefinition.id must match the landType parameter.
    ///   - initialStateFactory: Factory function that creates initial state for a given landType and landID.
    ///   - strategyFactory: Factory function that returns a MatchmakingStrategy for a given landType.
    public init(
        landFactory: @escaping @Sendable (String, LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (String, LandID) -> State,
        strategyFactory: @escaping @Sendable (String) -> any MatchmakingStrategy
    ) {
        self.landFactory = landFactory
        self.initialStateFactory = initialStateFactory
        self.strategyFactory = strategyFactory
    }
    
    /// Get LandDefinition for a land type.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (should match LandDefinition.id).
    ///   - landID: The unique identifier for the specific land instance.
    /// - Returns: The LandDefinition for this land type.
    /// - Precondition: The returned LandDefinition.id must match the landType parameter.
    public func getLandDefinition(landType: String, landID: LandID) -> LandDefinition<State> {
        let definition = landFactory(landType, landID)
        // Ensure consistency: definition.id should match landType
        assert(
            definition.id == landType,
            "LandDefinition.id (\(definition.id)) must match landType (\(landType))"
        )
        return definition
    }
}

