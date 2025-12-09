import Foundation
import Hummingbird
import SwiftStateTree
import Logging

/// Admin role for authorization.
public enum AdminRole: String, Codable, Sendable {
    case admin
    case `operator`
    case viewer
}

/// Admin authentication middleware for Hummingbird.
///
/// Validates admin JWT tokens or API keys and extracts admin role.
public struct AdminAuthMiddleware: Sendable {
    public let jwtValidator: JWTAuthValidator?
    public let apiKey: String?
    public let logger: Logger
    
    public init(
        jwtValidator: JWTAuthValidator? = nil,
        apiKey: String? = nil,
        logger: Logger? = nil
    ) {
        self.jwtValidator = jwtValidator
        self.apiKey = apiKey
        self.logger = logger ?? Logger(label: "com.swiftstatetree.admin")
    }
    
    /// Extract admin role from request.
    ///
    /// Checks JWT token or API key from request headers or query parameters.
    /// - Parameter request: The HTTP request.
    /// - Returns: AdminRole if authenticated, nil otherwise.
    public func extractAdminRole(from request: Request) async -> AdminRole? {
        // Try JWT token first
        if let validator = jwtValidator {
            // Extract token from Authorization header or query parameter
            var token: String?
            
            // Check Authorization header
            if let authHeader = request.headers[.authorization],
               authHeader.hasPrefix("Bearer ") {
                token = String(authHeader.dropFirst(7))
            }
            
            // Check query parameter
            if token == nil {
                let uriString = request.uri.description
                if let urlComponents = URLComponents(string: uriString),
                   let queryItems = urlComponents.queryItems,
                   let tokenItem = queryItems.first(where: { $0.name == "token" }),
                   let tokenValue = tokenItem.value {
                    token = tokenValue
                }
            }
            
            if let token = token {
                do {
                    let authInfo = try await validator.validate(token: token)
                    // Extract role from metadata
                    if let roleString = authInfo.metadata["adminRole"],
                       let role = AdminRole(rawValue: roleString) {
                        return role
                    }
                    // Default to admin if no role specified but token is valid
                    return .admin
                } catch {
                    logger.warning("Admin JWT validation failed: \(error)")
                }
            }
        }
        
        // Try API key
        if let apiKey = apiKey {
            // Check X-API-Key header
            for header in request.headers {
                if String(describing: header.name) == "X-API-Key" && header.value == apiKey {
                    return .admin
                }
            }
            
            // Check query parameter
            let uriString = request.uri.description
            if let urlComponents = URLComponents(string: uriString),
               let queryItems = urlComponents.queryItems,
               let apiKeyItem = queryItems.first(where: { $0.name == "apiKey" }),
               let apiKeyValue = apiKeyItem.value,
               apiKeyValue == apiKey {
                return .admin
            }
        }
        
        return nil
    }
    
    /// Check if the request has required admin role.
    ///
    /// - Parameters:
    ///   - request: The HTTP request.
    ///   - requiredRole: The minimum required role.
    /// - Returns: True if authenticated with sufficient role, false otherwise.
    public func hasRequiredRole(from request: Request, requiredRole: AdminRole) async -> Bool {
        guard let role = await extractAdminRole(from: request) else {
            return false
        }
        
        // Role hierarchy: admin > operator > viewer
        switch (role, requiredRole) {
        case (.admin, _):
            return true
        case (.operator, .operator), (.operator, .viewer):
            return true
        case (.viewer, .viewer):
            return true
        default:
            return false
        }
    }
}

