import Foundation

/// Type-erased wrapper for LandDefinition to enable schema generation
/// without requiring specific generic types.
public struct AnyLandDefinition: Sendable {
    /// The Land ID
    public let id: String
    
    /// The state type name
    public let stateTypeName: String
    
    private let _extractSchema: @Sendable () -> ProtocolSchema
    
    /// Create an AnyLandDefinition from a LandDefinition
    public init<State: StateNodeProtocol>(
        _ definition: LandDefinition<State>
    ) {
        self.id = definition.id
        self.stateTypeName = String(describing: State.self)
        self._extractSchema = {
            SchemaExtractor.extract(from: definition)
        }
    }
    
    /// Extract the protocol schema from this LandDefinition
    public func extractSchema() -> ProtocolSchema {
        _extractSchema()
    }
}

