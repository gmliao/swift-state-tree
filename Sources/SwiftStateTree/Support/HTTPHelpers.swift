// Sources/SwiftStateTree/Support/HTTPHelpers.swift
//
// Shared HTTP client helpers (fetch-style API). Use for outbound HTTP requests
// across SwiftStateTree modules (e.g. provisioning, metrics).

import Foundation

// MARK: - HTTP Status

/// Common HTTP status codes for branching and logging.
/// Use `HTTPStatusCode(rawValue: statusCode)` to look up known codes.
public enum HTTPStatusCode: Int, Sendable {
    case ok = 200
    case created = 201
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case notFound = 404
    case internalServerError = 500
    case serviceUnavailable = 503
}

extension HTTPURLResponse {
    /// True when status code is 2xx (successful). Prefer over raw range checks.
    public var isSuccess: Bool { (200...299).contains(statusCode) }

    /// Known status code enum, or nil for unlisted codes.
    public var statusCodeEnum: HTTPStatusCode? { HTTPStatusCode(rawValue: statusCode) }
}

/// Errors thrown by HTTPHelpers.
public enum HTTPHelpersError: Error, Sendable {
    /// Invalid input (e.g. empty HTTP method).
    case invalidInput(String)
    /// JSON encoding/serialization failed.
    case jsonEncodingFailed(underlying: Error)
    /// Network request failed (connection refused, timeout, etc.).
    case networkError(underlying: Error)
}

/// Shared HTTP helpers with fetch-style convenience API.
public enum HTTPHelpers: Sendable {

    /// Performs an HTTP request. Returns (data, response) or throws on error.
    ///
    /// - Parameters:
    ///   - url: Request URL
    ///   - method: HTTP method (GET, POST, PUT, DELETE, etc.). Must be non-empty.
    ///   - body: Optional request body. When non-nil, sets Content-Type to application/json.
    ///   - headers: Additional headers (optional)
    ///   - urlSession: URLSession to use (default: .shared). Inject custom session for testing.
    /// - Returns: (response data, HTTPURLResponse). Response may be nil for non-HTTP responses.
    /// - Throws: HTTPHelpersError on invalid input or network failure.
    public static func fetch(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse?) {
        let methodTrimmed = method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !methodTrimmed.isEmpty else {
            throw HTTPHelpersError.invalidInput("HTTP method cannot be empty")
        }

        var request = URLRequest(url: url)
        request.httpMethod = methodTrimmed
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch {
            throw HTTPHelpersError.networkError(underlying: error)
        }
    }

    /// Convenience: fetch with JSON body from Encodable.
    /// - Throws: HTTPHelpersError.jsonEncodingFailed when encoding fails; HTTPHelpersError.networkError on network failure.
    public static func fetch<T: Encodable>(
        url: URL,
        method: String = "POST",
        jsonBody: T,
        encoder: JSONEncoder = JSONEncoder(),
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse?) {
        let body: Data
        do {
            body = try encoder.encode(jsonBody)
        } catch {
            throw HTTPHelpersError.jsonEncodingFailed(underlying: error)
        }
        return try await fetch(url: url, method: method, body: body, headers: headers, urlSession: urlSession)
    }

    /// Convenience: fetch with JSON body from [String: Any] (uses JSONSerialization).
    /// - Throws: HTTPHelpersError.jsonEncodingFailed when object is not JSON-serializable; HTTPHelpersError.networkError on network failure.
    public static func fetch(
        url: URL,
        method: String = "POST",
        jsonObject: [String: Any],
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse?) {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: jsonObject)
        } catch {
            throw HTTPHelpersError.jsonEncodingFailed(underlying: error)
        }
        return try await fetch(url: url, method: method, body: body, headers: headers, urlSession: urlSession)
    }
}
