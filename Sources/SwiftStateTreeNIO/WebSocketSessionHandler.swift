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
    /// The close handshake started (this side's or the peer's close frame), or the handler was
    /// removed: no more writes. The channel may still be open, waiting for the close frame to be
    /// written, which a stalled client never lets happen.
    private var isClosed: Bool = false
    /// `context.close` was called: the channel itself is closing. The send backlog bound still
    /// acts while only `isClosed` is set (#61).
    private var channelCloseRequested = false

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
    /// Set by the connect closure when the transport rejects this connection (its `SessionID`
    /// is still held). Read only by closures on `inbound`, never by the event loop: the chain
    /// runs them one after another, so the connect closure's write is seen by every later one.
    private let rejection = InboundChainFlag()

    /// Waits until every inbound operation enqueued so far has run (tests).
    func waitForInboundIdle() async {
        await inbound.waitForIdle()
    }

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

    /// This session's outbound backlog, measured (#61 step 1); `sendBacklogBound` bounds it.
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
    /// When this session's backlog closes it (#61 step 3).
    let sendBacklogBound: SendBacklogBound
    /// The close of an episode that outlasts `sendBacklogBound.maxUnwritable`; scheduled when the
    /// episode opens (also while a close handshake waits), cancelled when it ends (writable
    /// again, or the handler removed).
    private var unwritableDeadline: Scheduled<Void>?
    /// The bound that closed this session, if one did.
    private(set) var sendBacklogBreach: SendBacklogBreach?
    /// The unwritable timer, if scheduled (tests check that it is cancelled, not just guarded).
    var unwritableDeadlineForTesting: Scheduled<Void>? { unwritableDeadline }

    init(
        sessionID: SessionID,
        path: String,
        transport: WebSocketTransport,
        authInfo: AuthenticatedInfo? = nil,
        eventLoop: any EventLoop,
        pongTimeout: TimeAmount = WebSocketSessionHandler.defaultPongTimeout,
        profilerCounters: TransportProfilerCounters? = nil,
        sendBacklogBound: SendBacklogBound = .default,
        logger: Logger
    ) {
        precondition(
            pongTimeout > .zero && pongTimeout < Self.pingInterval,
            "pongTimeout must be positive and below the ping interval (\(Self.pingInterval))"
        )
        self.pongTimeout = pongTimeout
        self.profilerCounters = profilerCounters
        self.sendBacklogBound = sendBacklogBound
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
            let acceptance = await self.transport.handleConnection(
                sessionID: self.sessionID,
                connection: connection,
                authInfo: self.authInfo
            )
            guard acceptance == .accepted else {
                // The transport closed the connection. Its frames and its disconnect are keyed by
                // a SessionID another connection holds, so none of them may reach the transport.
                self.rejection.set()
                self.logger.warning("WebSocket session rejected", metadata: [
                    "sessionID": .string(self.sessionID.rawValue),
                    "path": .string(self.path),
                ])
                return
            }

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
        unwritableDeadline?.cancel()  // also ended by the line above; kept explicit
        unwritableDeadline = nil
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
            // A rejected connection never had a session of its own to end.
            guard !self.rejection.isSet else { return }
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
            // A rejected connection's frames are dropped.
            guard !self.rejection.isSet else { return }
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
        channelCloseRequested = true
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
        if sendBacklogBound.maxBytes > 0, bytes > sendBacklogBound.maxBytes {
            closeForBacklog(.bytes(bytes))
        }
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
            let limit = sendBacklogBound.maxUnwritable
            // Also while a close handshake waits: its frame may never be written (#61).
            if limit > .zero, context != nil, !channelCloseRequested {
                unwritableDeadline = eventLoop.scheduleTask(in: limit) { [weak self] in
                    guard let self else { return }
                    self.unwritableDeadline = nil
                    // Cancelled tasks don't run; the check covers a cancel that came too late.
                    guard self.unwritableSince != nil else { return }
                    self.closeForBacklog(.unwritable(limit))
                }
            }
        } else if let since = unwritableSince {
            unwritableSince = nil
            unwritableDeadline?.cancel()
            unwritableDeadline = nil
            let duration = now - since
            if duration > sendBacklog.longestUnwritable { sendBacklog.longestUnwritable = duration }
            profilerCounters?.noteSendUnwritableEpisodeEnded(durationMs: Int(duration.nanoseconds / 1_000_000))
        }
    }

    /// Closes the session over its send backlog bound (#61 step 3, option A): a 4008 close frame,
    /// then the channel at once. The close frame queues behind the backlog it reacts to, so the
    /// channel is not kept open for its write: a client that isn't draining usually sees the TCP
    /// close (1006), not 4008. The profiler count and the warning are the record.
    ///
    /// A close handshake already started (a transport close of a stalled client, whose close
    /// frame waits behind the backlog) doesn't disarm it: the channel is closed without a second
    /// close frame. Counted once per session.
    private func closeForBacklog(_ breach: SendBacklogBreach) {
        eventLoop.assertInEventLoop()
        guard let context = context, !channelCloseRequested else { return }
        sendBacklogBreach = breach
        profilerCounters?.incrementSendBacklogCloses()
        var metadata: Logger.Metadata = [
            "sessionID": .string(sessionID.rawValue),
            "maxBytes": .stringConvertible(sendBacklogBound.maxBytes),
            "maxUnwritableMs": .stringConvertible(sendBacklogBound.maxUnwritable.nanoseconds / 1_000_000),
        ]
        switch breach {
        case .bytes(let bytes): metadata["bufferedBytes"] = .stringConvertible(bytes)
        case .unwritable(let time): metadata["unwritableMs"] = .stringConvertible(time.nanoseconds / 1_000_000)
        }
        metadata["closeHandshakeStarted"] = .stringConvertible(isClosed)
        logger.warning("Send backlog bound exceeded - closing connection", metadata: metadata)
        if !isClosed {
            isClosed = true
            var buffer = context.channel.allocator.buffer(capacity: 2)
            buffer.write(webSocketErrorCode: SendBacklogBound.closeCode)
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)), promise: nil)
        }
        channelCloseRequested = true
        context.close(promise: nil)
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
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { [weak self] _ in
            self?.channelCloseRequested = true
            context.close(promise: nil)
        }
    }
}
