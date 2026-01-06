import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Logging
import NIOCore
import HTTPTypes

// MARK: - WebSocket Router with Error Handling

/// Custom WebSocket router wrapper that provides better error messages when routes don't match.
struct WebSocketRouterWithErrorHandling<BaseRouter: HTTPResponderBuilder>: HTTPResponderBuilder 
where BaseRouter.Responder.Context: WebSocketRequestContext {
    let baseRouter: BaseRouter
    let getRegisteredPaths: @Sendable () async -> [String]
    let host: String
    let port: UInt16
    let logger: Logger
    
    func buildResponder() -> some HTTPResponder<BaseRouter.Responder.Context> {
        let baseResponder = baseRouter.buildResponder()
        return WebSocketRouterResponder(
            baseResponder: baseResponder,
            getRegisteredPaths: getRegisteredPaths,
            host: host,
            port: port,
            logger: logger
        )
    }
}

/// Custom HTTP responder that wraps the base router and provides better error messages.
struct WebSocketRouterResponder<BaseResponder: HTTPResponder>: HTTPResponder 
where BaseResponder.Context: WebSocketRequestContext {
    let baseResponder: BaseResponder
    let getRegisteredPaths: @Sendable () async -> [String]
    let host: String
    let port: UInt16
    let logger: Logger
    
    func respond(to request: Request, context: BaseResponder.Context) async throws -> Response {
        // Check if this is a WebSocket upgrade request
        let isWebSocketUpgrade = request.headers[.upgrade]?.lowercased() == "websocket" ||
                                 request.headers[.connection]?.lowercased().contains("upgrade") == true
        
        // Try the base router first
        let response = try await baseResponder.respond(to: request, context: context)
        
        // If it's a WebSocket upgrade request and the response is not OK, provide better error message
        if isWebSocketUpgrade && response.status != .ok {
            let requestedPath = request.uri.path
            let requestedURI = request.uri.description
            let registeredPaths = await getRegisteredPaths()
            
            logger.warning("❌ WebSocket upgrade failed: Path not found", metadata: [
                "requestedPath": .string(requestedPath),
                "requestedURI": .string(requestedURI),
                "responseStatus": .string("\(response.status)"),
                "registeredPaths": .string(registeredPaths.joined(separator: ", ")),
                "suggestion": .string("Check that the WebSocket URL path matches one of the registered endpoints")
            ])
            
            // Create error payload with consistent format
            let errorPayload = ErrorPayload(
                code: .websocketPathNotFound,
                message: "WebSocket path '\(requestedPath)' not found",
                details: [
                    "requestedPath": AnyCodable(requestedPath),
                    "requestedURI": AnyCodable(requestedURI),
                    "registeredPaths": AnyCodable(registeredPaths),
                    "availableEndpoints": AnyCodable(
                        registeredPaths.isEmpty 
                            ? "  (none registered)" 
                            : registeredPaths.map { "  - ws://\(host):\(port)\($0)" }.joined(separator: "\n")
                    )
                ]
            )
            
            // Return HTTP response with JSON error payload
            do {
                return try HTTPResponseHelpers.jsonResponse(errorPayload, status: .notFound)
            } catch {
                // Fallback to simple error response if JSON encoding fails
                return HTTPResponseHelpers.errorResponse(
                    message: "WebSocket path '\(requestedPath)' not found. Available: \(registeredPaths.joined(separator: ", "))",
                    status: .notFound
                )
            }
        }
        
        return response
    }
}
