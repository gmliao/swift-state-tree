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
    let authInfo: AuthenticatedInfo?
    let logger: Logger

    /// The channel's event loop. Every `var` below is read and written only on it: `send` and
    /// `close`, called from any thread, hop here before they look at `context` or `isClosed`
    /// (#144).
    private let eventLoop: any EventLoop
    /// Set in `handlerAdded`, cleared in `handlerRemoved`: a write never goes through the
    /// context of a removed handler.
    private var context: ChannelHandlerContext?
    private var connection: NIOWebSocketConnection?
    private var isClosed: Bool = false

    /// Pending messages to be processed in batch
    private var pendingMessages: [Data] = []
    /// Whether a flush task is scheduled
    private var flushScheduled: Bool = false
    /// Maximum messages per batch before immediate flush
    private static let maxBatchSize = 64

    /// Connect, message batches and disconnect reach the transport in this order (a join sent
    /// right after the upgrade must not overtake the connection's registration).
    private let inbound = InboundTaskChain()
    /// The disconnect went into `inbound` (exactly once, whoever started the close).
    private var disconnectEnqueued = false

    /// Fragment reassembly: buffer for accumulating fragmented message payloads
    private var fragmentBuffer: ByteBuffer?

    // MARK: - Ping/Pong Keepalive
    
    /// Time between pings.
    static let pingInterval: TimeAmount = .seconds(30)
    /// The pong timeout without configuration (`NIOWebSocketServerConfiguration.pongTimeout`).
    static let defaultPongTimeout: TimeAmount = .seconds(20)
    /// A ping followed by no inbound frame within this closes the connection with 1001 (#108).
    /// Any frame read from the peer counts as liveness, not only the pong (as in MQTT keepalive),
    /// so a live client whose pong is late but which keeps sending actions stays open. The clock
    /// starts when the ping is written to the channel, not when it reaches the wire. Below
    /// `pingInterval`, so each ping's deadline fires before the next ping.
    let pongTimeout: TimeAmount
    /// Counts pong-timeout closes when transport profiling is on.
    private let profilerCounters: TransportProfilerCounters?
    /// Scheduled ping task
    private var pingTask: Scheduled<Void>?
    /// The close of an unanswered ping, `pongTimeout` after it; cancelled by the pong.
    private var pongDeadline: Scheduled<Void>?
    /// Whether we're waiting for a pong response
    private var waitingForPong: Bool = false
    /// Last pong received time
    private var lastPongTime: NIODeadline = .now()

    // MARK: - Send backlog (#61)

    /// This session's outbound backlog, measured, not bounded (#61 step 1).
    struct SendBacklogStats: Equatable, Sendable {
        /// The largest `bufferedWritableBytes` sampled while the channel was unwritable: bytes
        /// NIO's outbound buffer held, written but not yet accepted by the socket. Sampled only
        /// above the high watermark (when the channel turns unwritable, and after each write
        /// while it stays so), so the writable path costs one `isWritable` read; 0 means the
        /// channel never went above it.
        var maxBufferedBytes = 0
        /// Times the channel became unwritable (above its high watermark).
        var unwritableEpisodes = 0
        /// The longest finished unwritable episode.
        var longestUnwritable: TimeAmount = .zero
    }
    /// Read and written on the event loop only, like the other state here.
    private(set) var sendBacklog = SendBacklogStats()
    /// When the current unwritable episode began, or `nil` while writable.
    private var unwritableSince: NIODeadline?

    init(
        sessionID: SessionID,
        path: String,
        transport: WebSocketTransport,
        authInfo: AuthenticatedInfo? = nil,
        eventLoop: any EventLoop,
        pongTimeout: TimeAmount = WebSocketSessionHandler.defaultPongTimeout,
        profilerCounters: TransportProfilerCounters? = nil,
        logger: Logger
    ) {
        precondition(
            pongTimeout > .zero && pongTimeout < Self.pingInterval,
            "pongTimeout must be positive and below the ping interval (\(Self.pingInterval))"
        )
        self.pongTimeout = pongTimeout
        self.profilerCounters = profilerCounters
        self.eventLoop = eventLoop
        self.sessionID = sessionID
        self.path = path
        self.transport = transport
        self.authInfo = authInfo
        self.logger = logger
    }

    // MARK: - ChannelInboundHandler

    func handlerAdded(context: ChannelHandlerContext) {
        precondition(context.eventLoop === eventLoop, "WebSocketSessionHandler added to a channel on another event loop")
        self.context = context

        // Create connection wrapper
        let connection = NIOWebSocketConnection(
            channel: context.channel,
            handler: self
        )
        self.connection = connection

        // Register with transport
        inbound.enqueue {
            await self.transport.handleConnection(
                sessionID: self.sessionID,
                connection: connection,
                authInfo: self.authInfo
            )

            self.logger.info(
                "WebSocket session connected",
                metadata: [
                    "sessionID": .string(self.sessionID.rawValue),
                    "path": .string(self.path),
                ]
            )
        }
        
        // Start ping keepalive, at this session's own phase of the interval (#108).
        schedulePing(context: context, in: Self.initialPingDelay(for: sessionID))
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // An episode still open ends with the session, so the profiler's gauge comes back down.
        // NIO runs this a tick after `channelInactive`, so that episode's length includes the
        // gap; it is small next to the profiler's 1 s windows.
        noteWritability(true, at: eventLoop.now)
        // Cancel ping task
        pingTask?.cancel()
        pingTask = nil
        pongDeadline?.cancel()
        pongDeadline = nil
        self.context = nil

        // Also after a close this handler started (`close(code:)`, e.g. a pong timeout) or a
        // client close frame: the transport must learn the session ended in every case.
        isClosed = true
        enqueueDisconnect()
    }

    /// Hands the session's disconnect to the transport after every message read before it.
    private func enqueueDisconnect() {
        guard !disconnectEnqueued else { return }
        disconnectEnqueued = true
        // A batch smaller than `maxBatchSize` is flushed from a later event-loop task; a frame
        // read in the same turn as the close would otherwise be enqueued after the disconnect.
        flushPendingMessages()
        inbound.enqueue {
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
        // Any frame from the peer shows it is alive: it answers an outstanding ping (#108).
        notePeerAlive()

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
        // A data frame read after the close (same read) would reach the transport after the
        // session's disconnect, as a message from an unknown session: drop it.
        guard !disconnectEnqueued else { return }
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

        inbound.enqueue {
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
    
    /// The peer sent a frame: an outstanding ping is answered and its deadline cancelled. Runs
    /// on the event loop (`channelRead`).
    private func notePeerAlive() {
        guard waitingForPong else { return }
        waitingForPong = false
        pongDeadline?.cancel()
        pongDeadline = nil
    }

    private func handlePong(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        // `channelRead` already answered the outstanding ping (`notePeerAlive`).
        lastPongTime = .now()
        
        logger.trace(
            "Received pong",
            metadata: [
                "sessionID": .string(sessionID.rawValue),
            ]
        )
    }
    
    // MARK: - Ping/Pong Keepalive
    
    /// The delay of a session's first ping: a stable offset in `(0, pingInterval)` from a hash of
    /// its session ID. Sessions that connect together (a ramp, a reconnect wave) then ping at
    /// different times, and keep those phases, instead of all at once every interval (#108).
    static func initialPingDelay(for sessionID: SessionID) -> TimeAmount {
        // FNV-1a, 64 bit: stable across processes (`hashValue` is seeded per process).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sessionID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let interval = UInt64(pingInterval.nanoseconds)
        let millisecond = UInt64(TimeAmount.milliseconds(1).nanoseconds)
        // At least 1 ms: no ping in the same turn as the connect.
        return .nanoseconds(Int64(max(millisecond, hash % interval)))
    }

    /// Schedule the next ping, `delay` from now.
    private func schedulePing(context: ChannelHandlerContext, in delay: TimeAmount = pingInterval) {
        guard !isClosed else { return }
        
        pingTask = context.eventLoop.scheduleTask(in: delay) { [weak self] in
            self?.sendPing()
        }
    }
    
    /// Send a ping frame to the client
    /// Runs on the event loop (a scheduled task).
    private func sendPing() {
        eventLoop.assertInEventLoop()
        guard let context = context, !isClosed else { return }
        
        // Send ping; without a pong within `pongTimeout`, the connection closes.
        waitingForPong = true
        let buffer = context.channel.allocator.buffer(capacity: 0)
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        pongDeadline?.cancel()
        // pongTimeout < pingInterval (init), so this deadline fires before the next ping.
        pongDeadline = context.eventLoop.scheduleTask(in: pongTimeout) { [weak self] in
            self?.closeIfPongMissing()
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

    /// Runs on the event loop, `pongTimeout` after a ping: no frame from the peer since, so it is gone.
    private func closeIfPongMissing() {
        eventLoop.assertInEventLoop()
        pongDeadline = nil
        guard waitingForPong, !isClosed else { return }
        profilerCounters?.incrementPongTimeoutCloses()
        logger.warning(
            "Pong timeout - closing connection",
            metadata: [
                "sessionID": .string(sessionID.rawValue),
                "pongTimeoutMs": .stringConvertible(pongTimeout.nanoseconds / 1_000_000),
            ]
        )
        closeOnLoop(code: .goingAway)
    }

    private func handleClose(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        guard !isClosed else { return }
        isClosed = true

        // Send close frame back
        let closeData = frame.unmaskedData
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeData)
        _ = context.writeAndFlush(wrapOutboundOut(closeFrame))
        context.close(promise: nil)

        enqueueDisconnect()
    }

    // MARK: - Outbound

    /// Sends a binary frame to the client. Callable from any thread: off the event loop it hops
    /// there, and the closed check runs in the same loop task as the write, so a send that races
    /// the handler's removal writes nothing. Calls from one thread keep their order.
    func send(_ buffer: ByteBuffer) {
        if eventLoop.inEventLoop {
            sendOnLoop(buffer)
        } else {
            eventLoop.execute { self.sendOnLoop(buffer) }
        }
    }

    private func sendOnLoop(_ buffer: ByteBuffer) {
        eventLoop.assertInEventLoop()
        guard let context = context, !isClosed else { return }
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        if !context.channel.isWritable {
            noteBufferedBytes(context: context)
        }
    }

    /// Samples the channel's outbound buffer: what flushes could not hand to the socket. Read
    /// from the channel (`bufferedWritableBytes`), not counted here.
    private func noteBufferedBytes(context: ChannelHandlerContext) {
        guard let bytes = try? context.channel.syncOptions?.getOption(.bufferedWritableBytes) else { return }
        if bytes > sendBacklog.maxBufferedBytes { sendBacklog.maxBufferedBytes = bytes }
        profilerCounters?.noteSendBufferedBytes(bytes)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let writable = context.channel.isWritable
        noteWritability(writable, at: eventLoop.now)
        if !writable {
            noteBufferedBytes(context: context)
        }
        context.fireChannelWritabilityChanged()
    }

    /// Opens an unwritable episode on the first `false`, closes it on the next `true`. Times
    /// come from the event loop's clock, so an embedded loop's tests control them.
    private func noteWritability(_ writable: Bool, at now: NIODeadline) {
        if !writable {
            guard unwritableSince == nil else { return }
            unwritableSince = now
            sendBacklog.unwritableEpisodes += 1
            profilerCounters?.noteSendUnwritableEpisodeStarted()
        } else if let since = unwritableSince {
            unwritableSince = nil
            let duration = now - since
            if duration > sendBacklog.longestUnwritable { sendBacklog.longestUnwritable = duration }
            profilerCounters?.noteSendUnwritableEpisodeEnded(durationMs: Int(duration.nanoseconds / 1_000_000))
        }
    }

    /// Closes the WebSocket connection (a close frame, then the channel). Callable from any
    /// thread, like `send`; a close after the handler's removal does nothing.
    func close(code: WebSocketErrorCode = .normalClosure) {
        if eventLoop.inEventLoop {
            closeOnLoop(code: code)
        } else {
            eventLoop.execute { self.closeOnLoop(code: code) }
        }
    }

    private func closeOnLoop(code: WebSocketErrorCode) {
        eventLoop.assertInEventLoop()
        guard let context = context, !isClosed else { return }
        isClosed = true

        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
