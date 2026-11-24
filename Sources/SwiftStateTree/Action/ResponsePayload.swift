import Foundation
import SwiftStateTurns

/// Marker protocol for action responses that should provide schema metadata.
///
/// Use `@Payload` to generate the required `getFieldMetadata()` implementation.
public protocol ResponsePayload: PlainData, Codable, Sendable, SchemaMetadataProvider, PayloadCompression {}
