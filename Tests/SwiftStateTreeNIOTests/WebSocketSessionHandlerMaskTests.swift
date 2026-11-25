// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerMaskTests.swift
// A client MUST mask every frame (RFC 6455 §5.1): the server fails the connection with 1002 on a
// frame that is not masked (#843). The close grace's side of this is in
// WebSocketSessionHandlerCloseGraceTests.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

private func makeSessionWithHandler(
    _ sessionID: String,
    transport: WebSocketTransport = WebSocketTransport()
) throws -> (EmbeddedChannel, WebSocketSessionHandler) {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(sessionID),
        path: "/test",
        transport: transport,
        eventLoop: channel.eventLoop,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(handler)
    return (channel, handler)
}

/// Records what the transport sees, in order (thread-safe).
private final class RecordingDelegate: TransportDelegate, @unchecked Sendable {
    enum Event: Equatable {
        case message(Data)
        case disconnect
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    var events: [Event] { lock.withLock { recorded } }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        lock.withLock { recorded.append(.disconnect) }
    }
    func onMessage(_ data: Data, from sessionID: SessionID) async {
        lock.withLock { recorded.append(.message(data)) }
    }
}

/// The frames written so far, in order.
private func written(_ channel: EmbeddedChannel) throws -> [WebSocketFrame] {
    var frames: [WebSocketFrame] = []
    while let frame = try channel.readOutbound(as: WebSocketFrame.self) { frames.append(frame) }
    return frames
}

/// The code of a close frame's payload.
private func code(of close: WebSocketFrame) -> UInt16? {
    var data = close.unmaskedData
    return data.readInteger(as: UInt16.self)
}

/// A frame as an unmasked client would send it: no mask key, the payload as is.
private func unmasked(
    fin: Bool = true, _ opcode: WebSocketOpcode, _ data: ByteBuffer = ByteBuffer()
) -> WebSocketFrame {
    let frame = WebSocketFrame(fin: fin, opcode: opcode, data: data)
    #expect(frame.maskKey == nil)
    return frame
}

@Suite("WebSocketSessionHandler refuses unmasked client frames (#843)")
struct WebSocketSessionHandlerMaskTests {
    @Test("An unmasked text frame: one close frame with 1002, cause error, no message, one disconnect")
    func unmaskedTextFails() async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let (channel, handler) = try makeSessionWithHandler("mask-text", transport: transport)

        try channel.writeInbound(unmasked(.text, ByteBuffer(string: "hello")))
        channel.embeddedEventLoop.run()
        await handler.waitForInboundIdle()

        let frames = try written(channel)
        #expect(frames.map(\.opcode) == [.connectionClose])
        #expect(frames.first.flatMap(code(of:)) == 1002)
        #expect(handler.closeCause == .error)
        #expect(!channel.isActive)
        #expect(recorder.events == [.disconnect], "no message reaches the transport, then one disconnect")
    }

    @Test("An unmasked ping: one close frame with 1002 and no pong")
    func unmaskedPingGetsNoPong() throws {
        let (channel, handler) = try makeSessionWithHandler("mask-ping")

        try channel.writeInbound(unmasked(.ping, ByteBuffer(string: "p")))
        channel.embeddedEventLoop.run()

        let frames = try written(channel)
        #expect(frames.map(\.opcode) == [.connectionClose], "no pong on the wire")
        #expect(frames.first.flatMap(code(of:)) == 1002)
        #expect(handler.closeCause == .error)
    }

    @Test("An unmasked close frame carrying 1000: our close frame is 1002, not an echo of 1000")
    func unmaskedCloseGets1002() throws {
        let (channel, handler) = try makeSessionWithHandler("mask-close")
        var payload = channel.allocator.buffer(capacity: 2)
        payload.write(webSocketErrorCode: .normalClosure)

        try channel.writeInbound(unmasked(.connectionClose, payload))
        channel.embeddedEventLoop.run()

        let frames = try written(channel)
        #expect(frames.map(\.opcode) == [.connectionClose])
        #expect(frames.first.flatMap(code(of:)) == 1002)
        #expect(handler.closeCause == .error)
    }

    @Test("An unmasked continuation in the middle of a masked fragmented message: 1002, the partial message is dropped")
    func unmaskedContinuationDropsPartialMessage() async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let (channel, handler) = try makeSessionWithHandler("mask-frag", transport: transport)

        try channel.writeInbound(WebSocketFrame.client(fin: false, opcode: .text, data: ByteBuffer(string: "par")))
        try channel.writeInbound(unmasked(.continuation, ByteBuffer(string: "tial")))
        channel.embeddedEventLoop.run()
        await handler.waitForInboundIdle()

        let frames = try written(channel)
        #expect(frames.map(\.opcode) == [.connectionClose])
        #expect(frames.first.flatMap(code(of:)) == 1002)
        #expect(recorder.events == [.disconnect], "the partial message never reaches the transport")
    }

    @Test("A masked frame with an all-zero key is masked: accepted, no close")
    func zeroKeyIsMasked() async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let (channel, handler) = try makeSessionWithHandler("mask-zero", transport: transport)
        let zero = WebSocketMaskingKey([0, 0, 0, 0])!

        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .text, maskKey: zero, data: ByteBuffer(string: "zero-key")))
        channel.embeddedEventLoop.run()
        await handler.waitForInboundIdle()

        #expect(recorder.events == [.message(Data("zero-key".utf8))])
        #expect(try written(channel).isEmpty, "no close frame goes out")
        #expect(handler.closeCause == nil)
        #expect(channel.isActive)
    }
}
