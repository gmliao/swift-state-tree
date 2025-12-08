import Foundation

// MARK: - Action Payload Protocol

/// Protocol for actions (RPC)
///
/// Each action must define its own Response type.
/// Action payloads must provide schema metadata via a macro-generated implementation.
public protocol ActionPayload: Codable, Sendable, SchemaMetadataProvider {
    associatedtype Response: ResponsePayload
    
    /// Macro-generated helper to expose the response type for schema extraction.
    ///
    /// The `@Payload` macro provides the concrete implementation. Calling this
    /// default implementation without the macro will trap at runtime.
    static func getResponseType() -> Any.Type
}

public extension ActionPayload {
    static func getResponseType() -> Any.Type {
        fatalError("getResponseType() must be implemented by @Payload macro for ActionPayload types")
    }
}
