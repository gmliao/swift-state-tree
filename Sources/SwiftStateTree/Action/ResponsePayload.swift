import Foundation

/// Marker protocol for action responses that should provide schema metadata.
///
/// Use `@Payload` to generate the required `getFieldMetadata()` implementation.
public protocol ResponsePayload: Codable, Sendable, SchemaMetadataProvider {}
