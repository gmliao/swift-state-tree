// Sources/SwiftStateTreeNIO/WebSocketSessionHandler.swift
//
// ChannelHandler for WebSocket sessions.

import Foundation
import Logging
import NIOCore
import NIOWebSocket
import SwiftStateTree
import SwiftStateTreeTransport

/// ChannelHandler that manages a single WebSocket session.
///
/// This handler:
/// - Processes incoming WebSocket frames
/// - Handles ping/pong automatically with keepalive
/// - Bridges to WebSocketTransport for message routing
/// - Uses batched message processing to reduce Task overhead
final class WebSocketSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let sessionID: SessionID
    let path: String
    let transport: WebSocketTransport
    let logger: Logger

    private var context: ChannelHandlerContext?
    private var connection: NIOWebSocketConnection?
    private var isClosed: Bool = false

    /// Pending messages to be processed in batch
    private var pendingMessages: [Data] = []
    /// Whether a flush task is scheduled
    private var flushScheduled: Bool = false
    /// Maximum messages per batch before immediate flush
    private static let maxBatchSize = 64

    /// Fragment reassembly: buffer for accumulating fragmented message payloads
    private var fragmentBuffer: ByteBuffer?

    // MARK: - Ping/Pong Keepalive
    
    /// Ping interval in seconds (default: 30 seconds)
    private static let pingInterval: TimeAmount = .seconds(30)
    /// Pong timeout in seconds (default: 10 seconds)
    private static let pongTimeout: TimeAmount = .seconds(10)
    /// Scheduled ping task
    private var pingTask: Scheduled<Void>?
    /// Whether we're waiting for a pong response
    private var waitingForPong: Bool = false
    /// Last pong received time
    private var lastPongTime: NIODeadline = .now()

    init(
        sessionID: SessionID,
        path: String,
        transport: WebSocketTransport,
        logger: Logger
    ) {
        self.sessionID = sessionID
        self.path = path
        self.transport = transport
        self.logger = logger
    }

    // MARK: - ChannelInboundHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context

        // Create connection wrapper
        let connection = NIOWebSocketConnection(
            channel: context.channel,
            handler: self
        )
        self.connection = connection

        // Register with transport
        Task {
            await self.transport.handleConnection(
                sessionID: self.sessionID,
                connection: connection,
                authInfo: nil  // TODO: Extract from query params
            )

            self.logger.info(
                "WebSocket session connected",
                metadata: [
                    "sessionID": .string(self.sessionID.rawValue),
                    "path": .string(self.path),
                ]
            )
        }
        
        // Start ping keepalive
        schedulePing(context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Cancel ping task
        pingTask?.cancel()
        pingTask = nil
        
        guard !isClosed else { return }
        isClosed = true

        Task {
            await self.transport.handleDisconnection(sessionID: self.sessionID)

            self.logger.info(
                "WebSocket session disconnected",
                metadata: [
                    "sessionID": .string(self.sessionID.rawValue),
                ]
            )
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary, .text, .continuation:
            handleDataFrame(frame, context: context)

        case .ping:
            handlePing(frame, context: context)

        case .pong:
            handlePong(frame, context: context)

        case .connectionClose:
            handleClose(frame, context: context)

        default:
            logger.warning("Received unknown opcode: \(frame.opcode)")
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error(
            "WebSocket error",
            metadata: [
                "sessionID": .string(sessionID.rawValue),
                "error": .string(String(describing: error)),
            ]
        )

        // Close on error
        context.close(promise: nil)
    }

    // MARK: - Frame Handlers

    private func handleDataFrame(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        switch result {
        case .complete(let data):
            enqueueMessage(data, context: context)

        case .incomplete:
            break

        case .ignored:
            logger.warning(
                "WebSocket frame ignored",
                metadata: [
                    "opcode": .string(String(describing: frame.opcode)),
                    "sessionID": .string(sessionID.rawValue),
                ]
            )

        case .exceededMaxSize:
            logger.warning(
                "Fragmented message exceeded max size (\(WebSocketFragmentReassembler.maxFragmentSize))",
                metadata: ["sessionID": .string(sessionID.rawValue)]
            )
        }
    }

    private func enqueueMessage(_ data: Data, context: ChannelHandlerContext) {
        pendingMessages.append(data)

        if pendingMessages.count >= Self.maxBatchSize {
            flushPendingMessages()
        } else if !flushScheduled {
            flushScheduled = true
            context.eventLoop.execute { [weak self] in
                self?.flushPendingMessages()
            }
        }
    }

    /// Flush all pending messages in a single Task
    private func flushPendingMessages() {
        flushScheduled = false
        guard !pendingMessages.isEmpty else { return }

        let messages = pendingMessages
        pendingMessages = []

        Task {
            for data in messages {
                await self.transport.handleIncomingMessage(
                    sessionID: self.sessionID,
                    data: data
                )
            }
        }
    }

    private func handlePing(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        // Respond with pong containing the same data
        let pongData = frame.unmaskedData
        let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
        context.writeAndFlush(wrapOutboundOut(pongFrame), promise: nil)
    }
    
    private func handlePong(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        // Update pong received state
        waitingForPong = false
        lastPongTime = .now()
        
        logger.trace(
            "Received pong",
            metadata: [
                "sessionID": .string(sessionID.rawValue),
            ]
        )
    }
    
    // MARK: - Ping/Pong Keepalive
    
    /// Schedule the next ping
    private func schedulePing(context: ChannelHandlerContext) {
        guard !isClosed else { return }
        
        pingTask = context.eventLoop.scheduleTask(in: Self.pingInterval) { [weak self] in
            self?.sendPing()
        }
    }
    
    /// Send a ping frame to the client
    private func sendPing() {
        guard let context = context, !isClosed else { return }
        
        // Check if we're still waiting for a previous pong
        if waitingForPong {
            // Client didn't respond to previous ping - connection may be dead
            logger.warning(
                "Pong timeout - closing connection",
                metadata: [
                    "sessionID": .string(sessionID.rawValue),
                ]
            )
            close(code: .goingAway)
            return
        }
        
        // Send ping
        waitingForPong = true
        let buffer = context.channel.allocator.buffer(capacity: 0)
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: buffer)
        
        if context.eventLoop.inEventLoop {
            context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        } else {
            context.eventLoop.execute {
                context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
            }
        }
        
        logger.trace(
            "Sent ping",
            metadata: [
                "sessionID": .string(sessionID.rawValue),
            ]
        )
        
        // Schedule next ping
        schedulePing(context: context)
    }

    private func handleClose(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        guard !isClosed else { return }
        isClosed = true

        // Send close frame back
        let closeData = frame.unmaskedData
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeData)
        _ = context.writeAndFlush(wrapOutboundOut(closeFrame))
        context.close(promise: nil)

        Task {
            await self.transport.handleDisconnection(sessionID: self.sessionID)
        }
    }

    // MARK: - Outbound

    /// Sends a binary frame to the client.
    /// Optimized: check if already on EventLoop to avoid unnecessary hop.
    func send(_ buffer: ByteBuffer) {
        guard let context = context, !isClosed else { return }

        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)

        if context.eventLoop.inEventLoop {
            // Fast path: already on correct EventLoop
            context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
        } else {
            // Slow path: hop to EventLoop
            context.eventLoop.execute {
                context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
            }
        }
    }

    /// Closes the WebSocket connection.
    func close(code: WebSocketErrorCode = .normalClosure) {
        guard let context = context, !isClosed else { return }
        isClosed = true

        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)

        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
        
        if context.eventLoop.inEventLoop {
            context.writeAndFlush(self.wrapOutboundOut(frame)).whenComplete { _ in
                context.close(promise: nil)
            }
        } else {
            context.eventLoop.execute {
                context.writeAndFlush(self.wrapOutboundOut(frame)).whenComplete { _ in
                    context.close(promise: nil)
                }
            }
        }
    }
}
