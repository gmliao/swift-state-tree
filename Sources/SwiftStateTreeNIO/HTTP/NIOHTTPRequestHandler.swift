// Sources/SwiftStateTreeNIO/HTTP/NIOHTTPRequestHandler.swift
//
// HTTP request handler for NIO servers with router support.

import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Handler for non-WebSocket HTTP requests with router support.
final class NIOHTTPRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let logger: Logger
    private let schemaProvider: @Sendable () -> Data?
    private let httpRouter: NIOHTTPRouter?

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(
        logger: Logger,
        schemaProvider: @escaping @Sendable () -> Data?,
        httpRouter: NIOHTTPRouter? = nil
    ) {
        self.logger = logger
        self.schemaProvider = schemaProvider
        self.httpRouter = httpRouter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)

        case .body(var buffer):
            requestBody?.writeBuffer(&buffer)

        case .end:
            guard let head = requestHead else {
                context.fireChannelRead(data)
                return
            }

            let path = head.uri.components(separatedBy: "?").first ?? head.uri

            // Try built-in routes first
            switch (head.method, path) {
            case (.GET, "/health"):
                sendHealthResponse(context: context)
                return

            case (.GET, "/schema"):
                sendSchemaResponse(context: context)
                return

            case (.OPTIONS, "/schema"):
                sendCORSPreflightResponse(context: context)
                return

            default:
                break
            }
            
            // Try HTTP router if available
            if let router = httpRouter {
                let bodyData: Data?
                if var buffer = requestBody, buffer.readableBytes > 0 {
                    bodyData = buffer.readBytes(length: buffer.readableBytes).map { Data($0) }
                } else {
                    bodyData = nil
                }
                
                let request = NIOHTTPRequest(
                    method: head.method,
                    uri: head.uri,
                    headers: head.headers,
                    body: bodyData
                )
                
                // Handle async router call on the event loop
                let eventLoop = context.eventLoop
                let channel = context.channel
                
                // Create a promise to track completion
                let promise = eventLoop.makePromise(of: Void.self)
                
                // Capture what we need in a Sendable way
                let routerCopy = router
                let loggerCopy = self.logger
                
                promise.completeWithTask {
                    do {
                        if let response = try await routerCopy.handle(request) {
                            // Execute response on the event loop
                            try await eventLoop.submit {
                                self.writeResponse(to: channel, response: response)
                            }.get()
                        } else {
                            // No matching route - 404
                            try await eventLoop.submit {
                                self.writeNotFoundResponse(to: channel, path: path)
                            }.get()
                        }
                    } catch {
                        loggerCopy.error("Router error: \(error)")
                        try? await eventLoop.submit {
                            self.writeErrorResponse(to: channel, status: .internalServerError, message: "Internal server error")
                        }.get()
                    }
                }
                
                requestHead = nil
                requestBody = nil
                return
            }

            // Pass through to next handler (WebSocket upgrade, etc.)
            context.fireChannelRead(data)

            requestHead = nil
            requestBody = nil
        }
    }

    // MARK: - Response Handlers (using context)

    private func sendHealthResponse(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "2")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var body = context.channel.allocator.buffer(capacity: 2)
        body.writeString("OK")
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func sendSchemaResponse(context: ChannelHandlerContext) {
        guard let schemaData = schemaProvider() else {
            sendErrorResponse(context: context, status: .notFound, message: "Schema not available")
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(schemaData.count)")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var body = context.channel.allocator.buffer(capacity: schemaData.count)
        body.writeBytes(schemaData)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func sendCORSPreflightResponse(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type")
        headers.add(name: "Access-Control-Max-Age", value: "86400")
        headers.add(name: "Content-Length", value: "0")

        let head = HTTPResponseHead(version: .http1_1, status: .noContent, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
    
    private func sendErrorResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var body = context.channel.allocator.buffer(capacity: message.utf8.count)
        body.writeString(message)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
    
    // MARK: - Response Handlers (using channel directly for async contexts)
    
    private func writeResponse(to channel: Channel, response: NIOHTTPResponse) {
        var headers = response.headers
        if let body = response.body {
            headers.replaceOrAdd(name: "Content-Length", value: "\(body.count)")
        } else {
            headers.replaceOrAdd(name: "Content-Length", value: "0")
        }
        
        let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        
        if let body = response.body {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
    
    private func writeNotFoundResponse(to channel: Channel, path: String) {
        writeErrorResponse(to: channel, status: .notFound, message: "Not found: \(path)")
    }

    private func writeErrorResponse(to channel: Channel, status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)

        var body = channel.allocator.buffer(capacity: message.utf8.count)
        body.writeString(message)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)

        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
