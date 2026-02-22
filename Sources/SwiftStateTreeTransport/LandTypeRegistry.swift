import Foundation
import SwiftStateTree

/// Registry for land types.
///
/// Maps each landType to:
/// - LandDefinition factory (how to create the land)
/// - Initial state factory (how to create initial state)
///
/// Each land type can have its own independent configuration, allowing different
/// behaviors for different types of lands.
public struct LandTypeRegistry<State: StateNodeProtocol>: Sendable {
    /// Factory: (landType, landID) -> LandDefinition
    /// The LandDefinition.id must match the landType.
    public let landFactory: @Sendable (String, LandID) -> LandDefinition<State>

    /// Factory: (landType, landID) -> State
    public let initialStateFactory: @Sendable (String, LandID) -> State

    /// Suffix appended to base land type to form the replay land type (e.g. "-replay").
    public let replayLandSuffix: String

    /// Initialize a LandTypeRegistry.
    ///
    /// - Parameters:
    ///   - landFactory: Factory function that creates a LandDefinition for a given landType and landID.
    ///     The returned LandDefinition.id must match the landType parameter.
    ///   - initialStateFactory: Factory function that creates initial state for a given landType and landID.
    ///   - replayLandSuffix: Suffix used to identify replay land types (default: "-replay").
    public init(
        landFactory: @escaping @Sendable (String, LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (String, LandID) -> State,
        replayLandSuffix: String = "-replay"
    ) {
        self.landFactory = landFactory
        self.initialStateFactory = initialStateFactory
        self.replayLandSuffix = replayLandSuffix
    }
    
    /// Get LandDefinition for a land type.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (should match LandDefinition.id).
    ///   - landID: The unique identifier for the specific land instance.
    /// - Returns: The LandDefinition for this land type.
    /// - Precondition: The returned LandDefinition.id must match landType, or landType must be
    ///   "{definition.id}-replay" (same-land replay convention).
    public func getLandDefinition(landType: String, landID: LandID) -> LandDefinition<State> {
        let definition = landFactory(landType, landID)
        // Ensure consistency: definition.id should match landType, or landType is replay alias
        let isReplayAlias = landType == "\(definition.id)\(replayLandSuffix)"
        assert(
            definition.id == landType || isReplayAlias,
            "LandDefinition.id (\(definition.id)) must match landType (\(landType))"
        )
        return definition
    }
}

