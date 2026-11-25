// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerDecoderErrorTests.swift
// Frame-decoder errors close once, with NIO's code, through the session's own close path (#827 F2).

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

// MARK: - Pipeline helper

/// Builds a channel whose inbound pipeline mirrors the production WebSocket pipeline after upgrade:
/// a `ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize:))`, an optional
/// `WebSocketProtocolErrorHandler` (only when `NIOWebSocketServer.automaticProtocolErrorHandling`
/// is true), and the session handler.  No `WebSocketFrameEncoder` is added so outbound writes are
/// readable as `WebSocketFrame` objects with `channel.readOutbound(as: WebSocketFrame.self)`.
private func makeDecoderPipeline(
    maxFrameSize: Int = 100,
    sessionID: String = "dec-s1",
    transport: WebSocketTransport = WebSocketTransport(),
    lifecycleLog: LandLifecycleLog? = nil,
    includeFlushHold: Bool = false
) throws -> (EmbeddedChannel, WebSocketSessionHandler, FlushHold?) {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(sessionID),
        path: "/test",
        transport: transport,
        eventLoop: channel.eventLoop,
        lifecycleLog: lifecycleLog,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(
        ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: maxFrameSize))
    )
    if NIOWebSocketServer.automaticProtocolErrorHandling {
        try channel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler())
    }
    var hold: FlushHold?
    if includeFlushHold {
        let h = FlushHold()
        try channel.pipeline.syncOperations.addHandler(h)
        hold = h
    }
    try channel.pipeline.syncOperations.addHandler(handler)
    return (channel, handler, hold)
}

/// Holds flushes until released — copied from `WebSocketSessionHandlerProtocolTests`.
private final class FlushHold: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = WebSocketFrame
    var holding = true
    func flush(context: ChannelHandlerContext) {
        if !holding { context.flush() }
    }
}

/// Counts every `connectionClose` frame in the outbound buffer and returns the codes.
private func outboundCloseCodes(_ channel: EmbeddedChannel) throws -> [UInt16] {
    var codes: [UInt16] = []
    while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
        guard frame.opcode == .connectionClose else { continue }
        var data = frame.unmaskedData
        if let code = data.readInteger(as: UInt16.self) {
            codes.append(code)
        } else {
            codes.append(0)
        }
    }
    return codes
}

// MARK: - Tests

@Suite("WebSocketSessionHandler: frame-decoder errors (#827 F2)")
struct WebSocketSessionHandlerDecoderErrorTests {

    // MARK: 1. Oversized frame → 1009, .error cause, logged

    @Test("A frame over maxFrameSize closes with 1009 and cause .error")
    func oversizedFrameCloses1009() throws {
        let lines = SessionLines()
        let (channel, handler, _) = try makeDecoderPipeline(
            maxFrameSize: 10,
            sessionID: "dec-oversize",
            lifecycleLog: lines.log
        )
        // Binary frame, length 11 (> maxFrameSize 10): [FIN+binary, unmasked len=11]
        var buf = channel.allocator.buffer(capacity: 2)
        buf.writeBytes([0x82, 0x0B])
        try channel.writeInbound(buf)
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        #expect(codes == [1009], "expected exactly one close frame with 1009, got \(codes)")
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)
        #expect(lines.records.first?.code == 1009)
        #expect(lines.records.first?.cause == .error)
    }

    // MARK: 2. Control frame > 125 bytes → 1002, .error cause

    @Test("A control frame with payload over 125 bytes closes with 1002")
    func oversizedControlFrameCloses1002() throws {
        // maxFrameSize must be > 125 so the frame-length check doesn't fire first; the
        // control-frame-specific check fires when it sees a control frame with length > 125.
        let (channel, handler, _) = try makeDecoderPipeline(
            maxFrameSize: 200,
            sessionID: "dec-ctrl-len"
        )
        // Ping, 2-byte extended length = 126: [FIN+ping, 0x7E, 0x00, 0x7E]
        var buf = channel.allocator.buffer(capacity: 4)
        buf.writeBytes([0x89, 0x7E, 0x00, 0x7E])
        try channel.writeInbound(buf)
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        #expect(codes == [1002], "expected exactly one 1002, got \(codes)")
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)
    }

    // MARK: 3. Fragmented control frame → 1002, .error cause

    @Test("A fragmented ping (FIN=0) closes with 1002")
    func fragmentedControlFrameCloses1002() throws {
        let (channel, handler, _) = try makeDecoderPipeline(sessionID: "dec-ctrl-frag")
        // Ping with FIN=0, len=0: [0x09, 0x00]
        var buf = channel.allocator.buffer(capacity: 2)
        buf.writeBytes([0x09, 0x00])
        try channel.writeInbound(buf)
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        #expect(codes == [1002], "expected exactly one 1002, got \(codes)")
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)
    }

    // MARK: 4. Server close held + oversized frame → one close frame, 1000, .serverClose

    @Test("A server close in flight followed by a decoder error sends exactly one close frame")
    func serverCloseHeldThenDecoderError() throws {
        let (channel, handler, hold) = try makeDecoderPipeline(
            maxFrameSize: 10,
            sessionID: "dec-repro",
            includeFlushHold: true
        )
        let h = try #require(hold)

        // Request a server close (1000); the flush is held, so the frame isn't on the wire yet.
        handler.close(code: .normalClosure)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive, "close write is held")

        // Send an oversized frame while the server close is pending.
        var buf = channel.allocator.buffer(capacity: 2)
        buf.writeBytes([0x82, 0x0B])
        try channel.writeInbound(buf)
        channel.embeddedEventLoop.run()

        // Release the hold so the pending frame(s) flush.
        h.holding = false
        channel.flush()
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        #expect(codes == [1000], "expected exactly one 1000 close frame, got \(codes)")
        #expect(handler.closeCause == .serverClose)
    }

    // MARK: 4b. Server close held + oversized frame + further read → still one close frame

    @Test("A further read while the close frame is held does not send a second close or discard the first")
    func serverCloseHeldThenDecoderErrorAndFurtherRead() throws {
        let lines = SessionLines()
        let (channel, handler, hold) = try makeDecoderPipeline(
            maxFrameSize: 10,
            sessionID: "dec-further",
            lifecycleLog: lines.log,
            includeFlushHold: true
        )
        let h = try #require(hold)

        // Request a server close (1000); the flush is held, so the frame isn't on the wire yet.
        handler.close(code: .normalClosure)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive, "close write is held")

        // Send an oversized frame — the decoder errors and failConnection is called.
        var buf = channel.allocator.buffer(capacity: 2)
        buf.writeBytes([0x82, 0x0B])
        try channel.writeInbound(buf)
        channel.embeddedEventLoop.run()

        // Send another frame — the decoder now fires dataReceivedInErrorState. The fix must
        // return early instead of calling closeChannel, leaving the pending close frame intact.
        var buf2 = channel.allocator.buffer(capacity: 2)
        buf2.writeBytes([0x82, 0x01])
        try channel.writeInbound(buf2)
        channel.embeddedEventLoop.run()

        // Release the hold so the pending frame flushes.
        h.holding = false
        channel.flush()
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        #expect(codes == [1000], "expected exactly one 1000 close frame, got \(codes)")
        #expect(!channel.isActive)
        #expect(handler.closeCause == .serverClose)
        #expect(lines.records.count == 1, "expected exactly one sessionClosed event, got \(lines.records.count)")
    }

    // MARK: 4c. Decoder failure during close grace → grace cancelled, channel closes

    @Test("A decoder failure during a close grace cancels the grace and closes the channel")
    func decoderErrorDuringCloseGraceCancelsGrace() throws {
        let (channel, handler, _) = try makeDecoderPipeline(sessionID: "dec-grace")

        // Start a close with a long grace so the deadline doesn't fire during the test.
        handler.close(code: .normalClosure, grace: .seconds(60))
        channel.embeddedEventLoop.run()

        // Write completes synchronously on EmbeddedChannel, so the grace should be active.
        #expect(handler.isInCloseGrace, "grace should be active after the close frame is written")
        #expect(handler.closeGraceDeadlineForTesting != nil)

        // Inject dataReceivedInErrorState directly (as ByteToMessageHandler would after a decode
        // error). The fix must cancel the grace and close the channel.
        let emptyBuffer = channel.allocator.buffer(capacity: 0)
        let origError = NIOWebSocket.NIOWebSocketError.invalidFrameLength
        channel.pipeline.fireErrorCaught(
            ByteToMessageDecoderError.dataReceivedInErrorState(origError, emptyBuffer)
        )
        channel.embeddedEventLoop.run()

        #expect(handler.closeGraceDeadlineForTesting == nil, "grace deadline must be cancelled")
        #expect(!channel.isActive)
        // The close frame written before the grace is in the buffer; no second one was added.
        let codes = try outboundCloseCodes(channel)
        #expect(codes == [1000], "expected exactly the initial 1000 close frame, got \(codes)")
    }

    // MARK: 5. IOError(ECONNRESET) → .connectionLost, no close frame

    @Test("An IOError(ECONNRESET) gives .connectionLost and sends no close frame")
    func econnresetGivesConnectionLost() throws {
        let (channel, handler, _) = try makeDecoderPipeline(sessionID: "dec-connreset")
        channel.pipeline.fireErrorCaught(IOError(errnoCode: ECONNRESET, reason: "reset"))
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        #expect(codes.isEmpty, "ECONNRESET must not send a close frame, got \(codes)")
        #expect(handler.closeCause == .connectionLost)
    }

    // MARK: 6. Generic error → .error with nil code, no close frame; channel closes

    @Test("A generic error gives .error with nil code and closes the channel without a close frame")
    func genericErrorGivesErrorCause() throws {
        struct E: Error {}
        let (channel, handler, _) = try makeDecoderPipeline(sessionID: "dec-generic")
        channel.pipeline.fireErrorCaught(E())
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        #expect(codes.isEmpty, "generic error must not send a close frame, got \(codes)")
        #expect(handler.closeCause == .error)
    }

    // MARK: 7. This module's NIOWebSocketError.connectionClosed → generic path (name-trap pin)

    @Test("SwiftStateTreeNIO.NIOWebSocketError.connectionClosed takes the generic path, not the decoder branch")
    func ownNIOWebSocketErrorTakesGenericPath() throws {
        let (channel, handler, _) = try makeDecoderPipeline(sessionID: "dec-name-trap")
        channel.pipeline.fireErrorCaught(NIOWebSocketError.connectionClosed)
        channel.embeddedEventLoop.run()

        let codes = try outboundCloseCodes(channel)
        // Generic path: closeChannel, no close frame; .error cause, nil code.
        #expect(codes.isEmpty, "our own NIOWebSocketError must not send a close frame, got \(codes)")
        #expect(handler.closeCause == .error)
    }
}
