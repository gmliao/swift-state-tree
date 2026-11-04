import Foundation
import SwiftStateTree

/// Protocol for abstracting LandServer implementations across different HTTP frameworks.
///
/// This protocol allows `LandRealm` to manage multiple `LandServer` instances
/// with different State types and different HTTP framework implementations
/// (e.g., Hummingbird, Vapor, Kitura) in a type-safe manner.
///
/// **Key Features**:
/// - Framework-agnostic abstraction
/// - Supports multiple State types
/// - Provides lifecycle management (shutdown, health check)
///
/// **Note**: HTTP server lifecycle (run) is managed by framework-specific hosting components
/// (e.g., `LandHost` for Hummingbird). The protocol no longer includes `run()` method.
///
/// **Implementation Note**:
/// Each HTTP framework should provide its own implementation of this protocol.
/// For example, `LandServer` in `SwiftStateTreeHummingbird` implements this protocol.
///
/// **Note**: The protocol does not require `Sendable` conformance because some
/// implementations (like `LandServer`) may contain non-Sendable types (e.g., Router).
/// The `LandRealm` actor handles thread safety internally.
///
/// **Example**:
/// ```swift
/// // Hummingbird implementation
/// extension LandServer: LandServerProtocol {
///     // Implementation details
/// }
///
/// // Future Vapor implementation
/// struct VaporLandServer<State: StateNodeProtocol>: LandServerProtocol {
///     // Implementation details
/// }
/// ```
public protocol LandServerProtocol<State> {
    associatedtype State: StateNodeProtocol
    
    /// Gracefully shutdown the server
    func shutdown() async throws
    
    /// Check the health status of the server
    func healthCheck() async -> Bool
    
    /// List all lands managed by this server
    ///
    /// Returns all land IDs across all land types managed by this server instance.
    func listLands() async -> [LandID]
    
    /// Get statistics for a specific land
    ///
    /// - Parameter landID: The unique identifier for the land
    /// - Returns: LandStats if the land exists, nil otherwise
    func getLandStats(landID: LandID) async -> LandStats?
    
    /// Remove a land from the server
    ///
    /// - Parameter landID: The unique identifier for the land to remove
    func removeLand(landID: LandID) async

    /// Get the current re-evaluation record for a land (if recording is enabled).
    ///
    /// - Parameter landID: The unique identifier for the land.
    /// - Returns: JSON data for the record, or nil if land/record not found.
    func getReevaluationRecord(landID: LandID) async throws -> Data?

    /// Freeze a land for a debug state check (see `TransportAdapter.debugFreeze()`).
    ///
    /// - Returns: nil if the land does not exist on this server.
    func debugFreeze(landID: LandID) async throws -> DebugFreezeResponse?

    /// Projection of a frozen land for `playerID`, or broadcast-only when `playerID` is nil.
    ///
    /// - Returns: nil if the land does not exist on this server.
    /// - Throws: `DebugFreezeError.notFrozen` if the land is not frozen.
    func debugProjection(landID: LandID, playerID: PlayerID?) async throws -> DebugProjectionResponse?

    /// Drop one freeze reference of a land.
    ///
    /// - Returns: nil if the land does not exist on this server.
    func debugResume(landID: LandID) async -> DebugResumeResponse?
}

extension LandServerProtocol {
    /// Default: debug freeze is not supported, the land is reported as not found.
    public func debugFreeze(landID: LandID) async throws -> DebugFreezeResponse? { nil }

    /// Default: debug freeze is not supported, the land is reported as not found.
    public func debugProjection(landID: LandID, playerID: PlayerID?) async throws -> DebugProjectionResponse? { nil }

    /// Default: debug freeze is not supported, the land is reported as not found.
    public func debugResume(landID: LandID) async -> DebugResumeResponse? { nil }
}
