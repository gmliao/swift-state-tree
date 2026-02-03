// Sources/SwiftStateTreeNIO/HTTP/NIOHTTPRouter.swift
//
// Lightweight HTTP router for NIO-based servers.

import Foundation
import Logging
import NIOCore
import NIOHTTP1

// MARK: - HTTP Route Handler

/// Result of an HTTP route handler.
public struct NIOHTTPResponse: Sendable {
    public let status: HTTPResponseStatus
    public let headers: HTTPHeaders
    public let body: Data?
    
    public init(status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders(), body: Data? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    
    // MARK: - Convenience Initializers
    
    /// Create a JSON response.
    public static func json<T: Encodable>(
        _ value: T,
        status: HTTPResponseStatus = .ok,
        encoder: JSONEncoder? = nil
    ) throws -> NIOHTTPResponse {
        let jsonEncoder = encoder ?? {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            return enc
        }()
        
        let data = try jsonEncoder.encode(value)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        
        return NIOHTTPResponse(status: status, headers: headers, body: data)
    }
    
    /// Create a JSON response from pre-encoded data.
    public static func json(data: Data, status: HTTPResponseStatus = .ok) -> NIOHTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        return NIOHTTPResponse(status: status, headers: headers, body: data)
    }
    
    /// Create a plain text response.
    public static func text(_ text: String, status: HTTPResponseStatus = .ok) -> NIOHTTPResponse {
        let data = Data(text.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        return NIOHTTPResponse(status: status, headers: headers, body: data)
    }
    
    /// Create an empty response (no content).
    public static func noContent(headers: HTTPHeaders = HTTPHeaders()) -> NIOHTTPResponse {
        var h = headers
        h.add(name: "Content-Length", value: "0")
        return NIOHTTPResponse(status: .noContent, headers: h, body: nil)
    }
    
    /// Add CORS headers to the response.
    public func withCORS(
        allowOrigin: String = "*",
        allowMethods: String = "GET, POST, DELETE, OPTIONS",
        allowHeaders: String = "Content-Type, X-API-Key, Authorization",
        maxAge: String? = nil
    ) -> NIOHTTPResponse {
        var newHeaders = headers
        newHeaders.replaceOrAdd(name: "Access-Control-Allow-Origin", value: allowOrigin)
        newHeaders.replaceOrAdd(name: "Access-Control-Allow-Methods", value: allowMethods)
        newHeaders.replaceOrAdd(name: "Access-Control-Allow-Headers", value: allowHeaders)
        if let maxAge = maxAge {
            newHeaders.replaceOrAdd(name: "Access-Control-Max-Age", value: maxAge)
        }
        return NIOHTTPResponse(status: status, headers: newHeaders, body: body)
    }
}

// MARK: - Request Context

/// Parsed HTTP request for route handlers.
public struct NIOHTTPRequest: Sendable {
    public let method: HTTPMethod
    public let uri: String
    public let path: String
    public let queryItems: [URLQueryItem]
    public let headers: HTTPHeaders
    public let body: Data?
    public let pathParameters: [String: String]
    
    public init(
        method: HTTPMethod,
        uri: String,
        headers: HTTPHeaders,
        body: Data?,
        pathParameters: [String: String] = [:]
    ) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
        self.pathParameters = pathParameters
        
        // Parse path and query
        let components = uri.components(separatedBy: "?")
        self.path = components.first ?? uri
        
        if components.count > 1, let urlComponents = URLComponents(string: uri) {
            self.queryItems = urlComponents.queryItems ?? []
        } else {
            self.queryItems = []
        }
    }
    
    /// Get a path parameter by name.
    public func pathParam(_ name: String) -> String? {
        pathParameters[name]?.removingPercentEncoding ?? pathParameters[name]
    }
    
    /// Get a query parameter by name.
    public func queryParam(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }
    
    /// Get a header value by name.
    public func header(_ name: String) -> String? {
        headers[name].first
    }
}

// MARK: - Route Definition

/// HTTP route handler closure type.
public typealias NIOHTTPHandler = @Sendable (NIOHTTPRequest) async throws -> NIOHTTPResponse

/// A registered HTTP route.
struct NIOHTTPRoute: Sendable {
    let method: HTTPMethod
    let pathPattern: String
    let pathComponents: [PathComponent]
    let handler: NIOHTTPHandler
    
    enum PathComponent: Sendable {
        case literal(String)
        case parameter(String)
        case wildcard
    }
    
    init(method: HTTPMethod, path: String, handler: @escaping NIOHTTPHandler) {
        self.method = method
        self.pathPattern = path
        self.handler = handler
        
        // Parse path into components
        var components: [PathComponent] = []
        for part in path.split(separator: "/") {
            let str = String(part)
            if str.hasPrefix(":") {
                components.append(.parameter(String(str.dropFirst())))
            } else if str == "*" {
                components.append(.wildcard)
            } else {
                components.append(.literal(str))
            }
        }
        self.pathComponents = components
    }
    
    /// Try to match a request path, extracting parameters.
    func match(path: String) -> [String: String]? {
        let requestParts = path.split(separator: "/").map(String.init)
        
        // Handle exact match for root
        if pathComponents.isEmpty && requestParts.isEmpty {
            return [:]
        }
        
        // Check component count (unless wildcard at end)
        if !pathComponents.contains(where: { if case .wildcard = $0 { return true } else { return false } }) {
            guard requestParts.count == pathComponents.count else { return nil }
        }
        
        var params: [String: String] = [:]
        
        for (index, component) in pathComponents.enumerated() {
            switch component {
            case .literal(let expected):
                guard index < requestParts.count, requestParts[index] == expected else { return nil }
            case .parameter(let name):
                guard index < requestParts.count else { return nil }
                params[name] = requestParts[index]
            case .wildcard:
                // Matches anything remaining
                return params
            }
        }
        
        return params
    }
}

// MARK: - HTTP Router

/// Lightweight HTTP router for NIO servers.
public actor NIOHTTPRouter {
    private var routes: [NIOHTTPRoute] = []
    private let logger: Logger
    
    public init(logger: Logger = Logger(label: "com.swiftstatetree.nio.router")) {
        self.logger = logger
    }
    
    // MARK: - Route Registration
    
    /// Register a GET route.
    public func get(_ path: String, handler: @escaping NIOHTTPHandler) {
        routes.append(NIOHTTPRoute(method: .GET, path: path, handler: handler))
    }
    
    /// Register a POST route.
    public func post(_ path: String, handler: @escaping NIOHTTPHandler) {
        routes.append(NIOHTTPRoute(method: .POST, path: path, handler: handler))
    }
    
    /// Register a DELETE route.
    public func delete(_ path: String, handler: @escaping NIOHTTPHandler) {
        routes.append(NIOHTTPRoute(method: .DELETE, path: path, handler: handler))
    }
    
    /// Register an OPTIONS route (for CORS preflight).
    public func options(_ path: String, handler: @escaping NIOHTTPHandler) {
        routes.append(NIOHTTPRoute(method: .OPTIONS, path: path, handler: handler))
    }
    
    /// Register a route with any method.
    public func on(_ method: HTTPMethod, _ path: String, handler: @escaping NIOHTTPHandler) {
        routes.append(NIOHTTPRoute(method: method, path: path, handler: handler))
    }
    
    // MARK: - Route Matching
    
    /// Find and execute a matching route handler.
    public func handle(_ request: NIOHTTPRequest) async throws -> NIOHTTPResponse? {
        for route in routes {
            guard route.method == request.method else { continue }
            guard let params = route.match(path: request.path) else { continue }
            
            // Create request with path parameters
            let requestWithParams = NIOHTTPRequest(
                method: request.method,
                uri: request.uri,
                headers: request.headers,
                body: request.body,
                pathParameters: params
            )
            
            return try await route.handler(requestWithParams)
        }
        
        return nil // No matching route
    }
    
    /// Get list of registered route patterns (for logging).
    public func registeredRoutes() -> [(method: String, path: String)] {
        routes.map { (String(describing: $0.method), $0.pathPattern) }
    }
}
