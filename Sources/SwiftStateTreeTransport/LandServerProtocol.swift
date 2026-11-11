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
    
    /// Stops a land (the admin API's `DELETE /admin/lands/:landID`, #102): its sessions leave
    /// and are closed with 4014 (`SessionClose.Code.landStopped`), then it is destroyed through
    /// the normal path (destroy handlers, the save). A tickless land runs each OnLeave before the
    /// destroy; a tick land's leaves are queued for its next tick, and the shutdown turn
    /// currently drops them (#512). A join for the same ID
    /// afterwards gets a new instance. Bounded by the host's `shutdownTimeout`: past it the
    /// result is `.stopped(timedOut: true)` and the destroy finishes in the background.
    ///
    /// - Parameter landID: The land to stop.
    /// - Returns: `.notFound` when no live instance has this ID.
    func stopLand(landID: LandID) async -> StopLandResult

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

    /// Drop one reference of the land's freeze identified by `freezeToken`.
    ///
    /// - Returns: nil if the land does not exist on this server.
    func debugResume(landID: LandID, freezeToken: String) async -> DebugResumeResponse?
}

extension LandServerProtocol {
    /// Default: debug freeze is not supported, the land is reported as not found.
    public func debugFreeze(landID: LandID) async throws -> DebugFreezeResponse? { nil }

    /// Default: debug freeze is not supported, the land is reported as not found.
    public func debugProjection(landID: LandID, playerID: PlayerID?) async throws -> DebugProjectionResponse? { nil }

    /// Default: debug freeze is not supported, the land is reported as not found.
    public func debugResume(landID: LandID, freezeToken: String) async -> DebugResumeResponse? { nil }
}
