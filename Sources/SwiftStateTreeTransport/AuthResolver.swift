// Sources/SwiftStateTreeTransport/AuthResolver.swift
//
// Framework-agnostic auth abstractions for WebSocket server integration.
// Any server (NIO, Vapor, Hummingbird, etc.) can use these protocols and pass
// the result into WebSocketTransport.handleConnection(sessionID:connection:authInfo:).

import Foundation

// MARK: - Token Validator Protocol

/// Protocol for validating a token string (e.g. JWT) and producing authenticated info.
///
/// Use this when your server extracts a token from the WebSocket handshake (query, header, or cookie)
/// and you want to validate it in a framework-agnostic way. Implementations can live in any module
/// (e.g. SwiftStateTreeNIO provides a JWT implementation); servers only depend on this protocol.
public protocol TokenValidatorProtocol: Sendable {
    /// Validates the token and returns authenticated info, or throws on invalid/expired token.
    func validate(token: String) async throws -> AuthenticatedInfo
}

// MARK: - Auth Info Resolver Protocol

/// Protocol for resolving authenticated info from the WebSocket handshake (path + full URI).
///
/// Called by the server before accepting the WebSocket. Implementations typically:
/// - Parse token from URI (e.g. `?token=...`) or from headers
/// - Optionally call a `TokenValidatorProtocol` to validate the token
/// - Return `nil` for guest/unauthenticated connections when allowed, or throw to reject
///
/// Any HTTP/WebSocket framework can implement this and pass the result to
/// `WebSocketTransport.handleConnection(sessionID:connection:authInfo:)`.
public protocol AuthInfoResolverProtocol: Sendable {
    /// Resolves auth info for the given path and full request URI.
    /// - Returns: AuthenticatedInfo for authenticated connections, nil for allowed guest, or throws to reject.
    func resolve(path: String, uri: String) async throws -> AuthenticatedInfo?
}

// MARK: - Closure-Based Resolver

/// Wraps a closure so it conforms to `AuthInfoResolverProtocol`.
/// Use this when you have a closure `(path, uri) async throws -> AuthenticatedInfo?` to pass to a server.
public struct ClosureAuthInfoResolver: AuthInfoResolverProtocol, Sendable {
    private let impl: @Sendable (String, String) async throws -> AuthenticatedInfo?

    public init(_ impl: @escaping @Sendable (String, String) async throws -> AuthenticatedInfo?) {
        self.impl = impl
    }

    public func resolve(path: String, uri: String) async throws -> AuthenticatedInfo? {
        try await impl(path, uri)
    }
}
