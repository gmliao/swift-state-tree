// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerFrameKindTests.swift
//
// #813: the handler accepts text and binary messages and passes each one's type on; a text
// message that isn't UTF-8 fails the connection with 1007; an outgoing message goes out in the
// frame type it was sent with.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

/// Records the messages delivered to the transport, with their frame type.
private final class KindRecordingDelegate: FrameKindTransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(Data, WebSocketFrameKind)] = []

    var messages: [(Data, WebSocketFrameKind)] { lock.withLock { recorded } }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {}
    func onMessage(_ data: Data, from sessionID: SessionID) async {
        Issue.record("a delegate that takes the kind gets the kind form")
    }
    func onMessage(_ data: Data, kind: WebSocketFrameKind, from sessionID: SessionID) async {
        lock.withLock { recorded.append((data, kind)) }
    }
}

private func makeHandler(
    _ sessionID: String,
    delegate: KindRecordingDelegate
) async throws -> (EmbeddedChannel, WebSocketSessionHandler) {
    let transport = WebSocketTransport()
    await transport.setDelegate(delegate)
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

private func frame(fin: Bool = true, _ opcode: WebSocketOpcode, _ bytes: [UInt8]) -> WebSocketFrame {
    WebSocketFrame(fin: fin, opcode: opcode, data: ByteBuffer(bytes: bytes))
}

/// The close code of the first close frame written, if any.
private func outboundCloseCode(_ channel: EmbeddedChannel) throws -> UInt16? {
    while let written = try channel.readOutbound(as: WebSocketFrame.self) {
        if written.opcode == .connectionClose {
            var data = written.unmaskedData
            return data.readInteger(as: UInt16.self)
        }
    }
    return nil
}

@Suite("WebSocketSessionHandler: text and binary messages (#813)")
struct WebSocketSessionHandlerFrameKindTests {
    @Test("Text and binary messages reach the delegate with their type, a split UTF-8 sequence included")
    func messagesKeepTheirType() async throws {
        let delegate = KindRecordingDelegate()
        let (channel, handler) = try await makeHandler("kind-in", delegate: delegate)
        try channel.writeInbound(frame(.text, Array("{\"a\":1}".utf8)))
        try channel.writeInbound(frame(.binary, [0x91, 0x01]))
        // "é" is C3 A9: the first fragment ends inside it.
        try channel.writeInbound(frame(fin: false, .text, [0x22, 0xC3]))
        try channel.writeInbound(frame(.continuation, [0xA9, 0x22]))
        channel.embeddedEventLoop.run()
        await handler.waitForInboundIdle()
        let messages = delegate.messages
        #expect(messages.map(\.1) == [.text, .binary, .text])
        #expect(messages.last?.0 == Data("\"\u{E9}\"".utf8))
        #expect(channel.isActive)
    }

    @Test("A text message that isn't UTF-8 closes with 1007 and reaches nothing",
          arguments: [false, true])
    func invalidUTF8ClosesWith1007(fragmented: Bool) async throws {
        let delegate = KindRecordingDelegate()
        let (channel, handler) = try await makeHandler("kind-bad-\(fragmented)", delegate: delegate)
        if fragmented {
            try channel.writeInbound(frame(fin: false, .text, Array("ok".utf8)))
            try channel.writeInbound(frame(.continuation, [0xCE, 0xBA, 0xE1, 0xBD, 0xB9, 0xCF, 0x83, 0xCE, 0xBC, 0xCE, 0xB5, 0xED, 0xA0, 0x80]))
        } else {
            try channel.writeInbound(frame(.text, [0xF8, 0x88, 0x80, 0x80, 0x80]))
        }
        // A frame after the failure is dropped.
        try channel.writeInbound(frame(.text, Array("late".utf8)))
        channel.embeddedEventLoop.run()
        #expect(try outboundCloseCode(channel) == 1007)
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)
        await handler.waitForInboundIdle()
        #expect(delegate.messages.isEmpty, "nothing reaches the transport")
    }

    @Test("An outgoing message goes out in the frame type it was sent with")
    func outgoingOpcodeFollowsTheKind() async throws {
        let (channel, handler) = try await makeHandler("kind-out", delegate: KindRecordingDelegate())
        handler.send(ByteBuffer(string: "{}"), kind: .text)
        handler.send(ByteBuffer(bytes: [0x90]), kind: .binary)
        channel.embeddedEventLoop.run()
        var opcodes: [WebSocketOpcode] = []
        while let written = try channel.readOutbound(as: WebSocketFrame.self) {
            opcodes.append(written.opcode)
        }
        #expect(opcodes == [.text, .binary])
    }

    @Test("A ping between a text opener and its continuation is answered, and the message arrives once, as text (RFC 6455 §5.4)")
    func pingInsideAFragmentedMessage() async throws {
        let delegate = KindRecordingDelegate()
        let (channel, handler) = try await makeHandler("kind-ping", delegate: delegate)
        try channel.writeInbound(frame(fin: false, .text, Array("{\"a\":".utf8)))
        try channel.writeInbound(frame(.ping, Array("p".utf8)))
        try channel.writeInbound(frame(.continuation, Array("1}".utf8)))
        channel.embeddedEventLoop.run()
        var written: [WebSocketFrame] = []
        while let next = try channel.readOutbound(as: WebSocketFrame.self) { written.append(next) }
        #expect(written.map(\.opcode) == [.pong], "only the pong is written")
        #expect(written.first.map { Array($0.unmaskedData.readableBytesView) } == Array("p".utf8), "the pong echoes the ping's payload")
        await handler.waitForInboundIdle()
        let messages = delegate.messages
        #expect(messages.count == 1)
        #expect(messages.first?.0 == Data("{\"a\":1}".utf8))
        #expect(messages.first?.1 == .text)
        #expect(channel.isActive)
    }

    @Test("NIOWebSocketConnection.send(_:kind:) writes the frame type it is given")
    func connectionSendsTheKind() async throws {
        let (channel, handler) = try await makeHandler("kind-conn", delegate: KindRecordingDelegate())
        let connection = NIOWebSocketConnection(channel: channel, handler: handler)
        try await connection.send(Data("{}".utf8), kind: .text)
        try await connection.send(Data([0x90]), kind: .binary)
        channel.embeddedEventLoop.run()
        var opcodes: [WebSocketOpcode] = []
        while let written = try channel.readOutbound(as: WebSocketFrame.self) { opcodes.append(written.opcode) }
        #expect(opcodes == [.text, .binary])
    }
}
