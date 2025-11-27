import Foundation

// MARK: - Action Payload Protocol

/// Protocol for actions (RPC)
///
/// Each action must define its own Response type.
public protocol ActionPayload: Codable, Sendable {
    associatedtype Response: Codable & Sendable
}
