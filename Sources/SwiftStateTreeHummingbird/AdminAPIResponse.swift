import Foundation
import SwiftStateTree

/// Admin API error codes.
public enum AdminAPIErrorCode: String, Codable, Sendable {
    case unauthorized = "UNAUTHORIZED"
    case forbidden = "FORBIDDEN"
    case notFound = "NOT_FOUND"
    case internalError = "INTERNAL_ERROR"
    case invalidRequest = "INVALID_REQUEST"
    case notImplemented = "NOT_IMPLEMENTED"
}

/// Admin API error information.
public struct AdminAPIError: Codable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: AnyCodable]?
    
    public init(code: AdminAPIErrorCode, message: String, details: [String: AnyCodable]? = nil) {
        self.code = code.rawValue
        self.message = message
        self.details = details
    }
    
    public init(code: String, message: String, details: [String: AnyCodable]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Unified Admin API response format.
///
/// All admin API endpoints return responses in this format:
/// - Success: `{ "success": true, "data": ... }`
/// - Error: `{ "success": false, "error": { "code": "...", "message": "..." } }`
public struct AdminAPIResponse<T: Codable & Sendable>: Codable, Sendable {
    public let success: Bool
    public let data: T?
    public let error: AdminAPIError?
    
    private init(success: Bool, data: T?, error: AdminAPIError?) {
        self.success = success
        self.data = data
        self.error = error
    }
    
    /// Create a successful response with data.
    public static func success(_ data: T) -> AdminAPIResponse<T> {
        AdminAPIResponse(success: true, data: data, error: nil)
    }
    
    /// Create an error response.
    public static func error(_ error: AdminAPIError) -> AdminAPIResponse<T> {
        AdminAPIResponse(success: false, data: nil, error: error)
    }
    
    /// Create an error response with error code and message.
    public static func error(code: AdminAPIErrorCode, message: String, details: [String: AnyCodable]? = nil) -> AdminAPIResponse<T> {
        AdminAPIResponse(success: false, data: nil, error: AdminAPIError(code: code, message: message, details: details))
    }
}

// MARK: - Type Erased Response

/// Type-erased admin API response for endpoints that return different data types.
public struct AdminAPIAnyResponse: Codable, Sendable {
    public let success: Bool
    public let data: AnyCodable?
    public let error: AdminAPIError?
    
    private init(success: Bool, data: AnyCodable?, error: AdminAPIError?) {
        self.success = success
        self.data = data
        self.error = error
    }
    
    /// Create a successful response with any codable data.
    public static func success<T: Codable>(_ data: T) -> AdminAPIAnyResponse {
        AdminAPIAnyResponse(success: true, data: AnyCodable(data), error: nil)
    }
    
    /// Create an error response.
    public static func error(_ error: AdminAPIError) -> AdminAPIAnyResponse {
        AdminAPIAnyResponse(success: false, data: nil, error: error)
    }
    
    /// Create an error response with error code and message.
    public static func error(code: AdminAPIErrorCode, message: String, details: [String: AnyCodable]? = nil) -> AdminAPIAnyResponse {
        AdminAPIAnyResponse(success: false, data: nil, error: AdminAPIError(code: code, message: message, details: details))
    }
}
