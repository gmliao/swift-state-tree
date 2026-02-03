// Sources/SwiftStateTreeNIO/HTTP/NIOAdminAuth.swift
//
// Admin authentication for NIO-based servers.

import Foundation
import Logging
import NIOHTTP1
import SwiftStateTreeTransport

/// Admin authentication for NIO servers.
///
/// Validates API keys from request headers or query parameters.
/// Note: JWT authentication is not supported in NIO mode - use Hummingbird for JWT support.
public struct NIOAdminAuth: Sendable {
    public let apiKey: String?
    public let logger: Logger
    
    public init(
        apiKey: String? = nil,
        logger: Logger? = nil
    ) {
        self.apiKey = apiKey
        self.logger = logger ?? Logger(label: "com.swiftstatetree.nio.admin")
    }
    
    /// Extract admin role from request.
    ///
    /// Checks API key from request headers or query parameters.
    /// - Parameter request: The HTTP request.
    /// - Returns: AdminRole if authenticated, nil otherwise.
    public func extractAdminRole(from request: NIOHTTPRequest) -> AdminRole? {
        guard let expectedKey = apiKey else {
            // No API key configured - deny all
            return nil
        }
        
        // Check X-API-Key header
        if let headerKey = request.header("X-API-Key"), headerKey == expectedKey {
            return .admin
        }
        
        // Check query parameter
        if let queryKey = request.queryParam("apiKey"), queryKey == expectedKey {
            return .admin
        }
        
        return nil
    }
    
    /// Check if the request has required admin role.
    ///
    /// - Parameters:
    ///   - request: The HTTP request.
    ///   - requiredRole: The minimum required role.
    /// - Returns: True if authenticated with sufficient role, false otherwise.
    public func hasRequiredRole(from request: NIOHTTPRequest, requiredRole: AdminRole) -> Bool {
        guard let role = extractAdminRole(from: request) else {
            return false
        }
        return role.hasPermission(for: requiredRole)
    }
}
