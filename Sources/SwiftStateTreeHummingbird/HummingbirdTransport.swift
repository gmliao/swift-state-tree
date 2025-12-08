import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTreeTransport
import SwiftStateTree
import NIOCore
import NIOFoundationCompat
import HTTPTypes

/// Adapter to use Hummingbird WebSockets with SwiftStateTreeTransport.
public struct HummingbirdStateTreeAdapter: Sendable {
    /// The transport instance managing the state tree connections.
    public let transport: WebSocketTransport
    /// Optional JWT validator for authentication during handshake
    public let jwtValidator: JWTAuthValidator?
    /// Whether guest mode is allowed (connections without JWT token)
    public let allowGuestMode: Bool
    
    public init(
        transport: WebSocketTransport,
        jwtValidator: JWTAuthValidator? = nil,
        allowGuestMode: Bool = false
    ) {
        self.transport = transport
        self.jwtValidator = jwtValidator
        self.allowGuestMode = allowGuestMode
    }
    
    /// Handler for Hummingbird WebSocket connection.
    ///
    /// If `jwtValidator` is configured, this handler will:
    /// 1. Extract the JWT token from the `token` query parameter in the WebSocket URL
    /// 2. Validate the token using the configured validator
    /// 3. Close the connection with `policyViolation` if validation fails or token is missing
    /// 4. Pass the authenticated information (`AuthenticatedInfo`) to the transport if validation succeeds
    ///
    /// Example WebSocket URL: `ws://localhost:8080/game?token=<jwt-token>`
    ///
    /// Usage:
    /// ```swift
    /// let adapter = HummingbirdStateTreeAdapter(transport: myTransport, jwtValidator: myValidator)
    /// router.ws("/ws") { inbound, outbound, context in
    ///     await adapter.handle(inbound: inbound, outbound: outbound, context: context)
    /// }
    /// ```
    public func handle(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        context: some WebSocketContext
    ) async {
        // Extract JWT token from Authorization header if validator is configured
        var authInfo: AuthenticatedInfo? = nil
        
        if let validator = jwtValidator {
            // Extract JWT token from query parameter "token"
            // This is simpler and works with standard WebSocket API in browsers
            var token: String? = nil
            
            if let routerContext = context as? WebSocketRouterContext<BasicWebSocketRequestContext> {
                // Extract token from query parameters
                let uriString = routerContext.request.uri.description
                if let urlComponents = URLComponents(string: uriString),
                   let queryItems = urlComponents.queryItems,
                   let tokenItem = queryItems.first(where: { $0.name == "token" }),
                   let tokenValue = tokenItem.value {
                    token = tokenValue
                }
            }
            
            if let token = token {
                do {
                    authInfo = try await validator.validate(token: token)
                } catch {
                    // Close connection on auth failure
                    try? await outbound.close(.policyViolation, reason: "Invalid or expired token")
                    return
                }
            } else {
                // No token provided
                if allowGuestMode {
                    // Allow connection as guest (authInfo remains nil)
                    // Guest session will be created in handleJoinRequest
                } else {
                    // Reject connection if guest mode is disabled
                    try? await outbound.close(.policyViolation, reason: "Missing token query parameter")
                    return
                }
            }
        }
        
        // Generate a session ID (in a real app, this might come from auth headers or handshake)
        let sessionID = SessionID(UUID().uuidString)
        
        // Create connection wrapper
        let connection = HummingbirdWebSocketConnection(outbound: outbound)
        
        // Register connection with auth info
        // Note: WebSocketTransport.handleConnection needs to be updated to accept authInfo
        await transport.handleConnection(sessionID: sessionID, connection: connection, authInfo: authInfo)
        
        // Handle incoming messages
        do {
            for try await message in inbound.messages(maxSize: .max) {
                switch message {
                case .text(let text):
                    if let data = text.data(using: .utf8) {
                        await transport.handleIncomingMessage(sessionID: sessionID, data: data)
                    }
                case .binary(let buffer):
                    var mutableBuffer = buffer
                    if let data = mutableBuffer.readData(length: mutableBuffer.readableBytes) {
                        await transport.handleIncomingMessage(sessionID: sessionID, data: data)
                    }
                }
            }
        } catch {
            // Connection error
        }
        
        // Handle disconnection
        await transport.handleDisconnection(sessionID: sessionID)
    }
}

/// Concrete implementation of WebSocketConnection for Hummingbird.
public struct HummingbirdWebSocketConnection: WebSocketConnection {
    let outbound: WebSocketOutboundWriter
    
    public func send(_ data: Data) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await outbound.write(.binary(buffer))
    }
    
    public func close() async throws {
        try await outbound.close(.normalClosure, reason: nil)
    }
}
