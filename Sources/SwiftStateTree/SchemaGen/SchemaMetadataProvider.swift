import Foundation

/// Protocol for types that provide metadata for schema generation.
/// Both StateNodes (via @StateNodeBuilder) and Actions/Events (via @Schemable) conform to this.
public protocol SchemaMetadataProvider {
    /// Get metadata for all fields in this type.
    static func getFieldMetadata() -> [FieldMetadata]
}
