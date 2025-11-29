import Foundation

// MARK: - Action Payload Protocol

/// Protocol for actions (RPC)
///
/// Each action must define its own Response type.
/// Action payloads must provide schema metadata via a macro-generated implementation.
public protocol ActionPayload: Codable, Sendable, SchemaMetadataProvider {
    associatedtype Response: Codable & Sendable
}
