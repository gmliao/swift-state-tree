import Foundation
import Hummingbird
import NIOCore

// MARK: - JSON Response Helpers

/// Helper functions for creating JSON HTTP responses in Hummingbird.
public enum HTTPResponseHelpers {
    /// Create a JSON response from an encodable value.
    ///
    /// - Parameters:
    ///   - value: The value to encode as JSON (must conform to `Encodable`)
    ///   - status: HTTP status code (default: `.ok`)
    ///   - encoder: Optional custom JSON encoder (default: uses pretty-printed encoder)
    /// - Returns: HTTP response with JSON body
    /// - Throws: Encoding errors if JSON encoding fails
    public static func jsonResponse<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status = .ok,
        encoder: JSONEncoder? = nil
    ) throws -> Response {
        let jsonEncoder = encoder ?? {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return enc
        }()
        
        let jsonData = try jsonEncoder.encode(value)
        var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
        buffer.writeBytes(jsonData)
        var response = Response(status: status, body: .init(byteBuffer: buffer))
        response.headers[.contentType] = "application/json"
        return response
    }
    
    /// Create a JSON response from pre-encoded JSON data.
    ///
    /// This is useful when you already have encoded JSON data (e.g., from cache).
    ///
    /// - Parameters:
    ///   - jsonData: Pre-encoded JSON data
    ///   - status: HTTP status code (default: `.ok`)
    /// - Returns: HTTP response with JSON body
    public static func jsonResponse(
        from jsonData: Data,
        status: HTTPResponse.Status = .ok
    ) -> Response {
        var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
        buffer.writeBytes(jsonData)
        var response = Response(status: status, body: .init(byteBuffer: buffer))
        response.headers[.contentType] = "application/json"
        return response
    }
    
    /// Create an error response with a JSON error message.
    ///
    /// - Parameters:
    ///   - message: Error message
    ///   - status: HTTP status code (default: `.internalServerError`)
    /// - Returns: HTTP response with JSON error body
    public static func errorResponse(
        message: String,
        status: HTTPResponse.Status = .internalServerError
    ) -> Response {
        let errorBody: [String: String] = ["error": message]
        do {
            return try jsonResponse(errorBody, status: status)
        } catch {
            // Fallback to plain text if JSON encoding fails
            var buffer = ByteBufferAllocator().buffer(capacity: message.utf8.count)
            buffer.writeString(message)
            return Response(status: status, body: .init(byteBuffer: buffer))
        }
    }
}
