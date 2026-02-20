import Foundation

/// Type-erased wrapper for LandDefinition to enable schema generation
/// without requiring specific generic types.
public struct AnyLandDefinition: Sendable {
    /// The Land ID
    public let id: String

    /// Optional alias: when set, the schema will include an additional land entry
    /// with this name, sharing the same LandSchema (e.g. "hero-defense-replay" for same-land replay).
    public let alias: String?

    /// The state type name
    public let stateTypeName: String

    private let _extractSchema: @Sendable () -> ProtocolSchema

    /// Create an AnyLandDefinition from a LandDefinition.
    /// - Parameters:
    ///   - definition: The land definition to wrap.
    ///   - alias: Optional alias name; when provided, schema generation adds this land with the same schema.
    public init<State: StateNodeProtocol>(
        _ definition: LandDefinition<State>,
        alias: String? = nil
    ) {
        self.id = definition.id
        self.alias = alias
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

