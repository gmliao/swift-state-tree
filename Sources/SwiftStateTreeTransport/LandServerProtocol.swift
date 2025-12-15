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
/// - Provides lifecycle management (run, shutdown, health check)
///
/// **Implementation Note**:
/// Each HTTP framework should provide its own implementation of this protocol.
/// For example, `LandServer` (formerly `AppContainer`) in `SwiftStateTreeHummingbird` implements this protocol.
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
    
    /// Start the server
    func run() async throws
    
    /// Gracefully shutdown the server
    func shutdown() async throws
    
    /// Check the health status of the server
    func healthCheck() async -> Bool
}
