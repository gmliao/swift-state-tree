import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Extension to make LandServer conform to LandServerProtocol.
///
/// This allows LandServer to be used with LandRealm and other components
/// that work with the LandServerProtocol abstraction.
extension LandServer: LandServerProtocol {
    /// Gracefully shutdown the server.
    ///
    /// Note: Currently, LandServer doesn't have explicit shutdown support.
    /// This is a placeholder for future implementation.
    public func shutdown() async throws {
        // TODO: Implement graceful shutdown for LandServer
        // This might involve:
        // - Stopping accepting new connections
        // - Waiting for existing connections to close
        // - Cleaning up resources
    }
    
    /// Check the health status of the server.
    ///
    /// For now, we consider a server healthy if it exists.
    /// In a real implementation, we might check if the server is running,
    /// if it can accept connections, etc.
    public func healthCheck() async -> Bool {
        // TODO: Implement actual health check
        // This might involve:
        // - Checking if the server is running
        // - Checking if it can accept connections
        // - Checking resource usage
        return true
    }
}
