// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerProtocolTests.swift
// Tests for RFC 6455 protocol enforcement: RSV bits, reserved opcodes, close validation (#810),
// bad fragment sequences (#822).

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

private func makeSessionWithHandler(
    _ sessionID: String = "proto-s1",
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

private func makeSession(_ sessionID: String = "proto-s1") throws -> EmbeddedChannel {
    try makeSessionWithHandler(sessionID).0
}

/// Records messages delivered to the transport (thread-safe).
private final class RecordingDelegate: TransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [Data] = []

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {}
    func onMessage(_ data: Data, from sessionID: SessionID) async {
        lock.withLock { messages.append(data) }
    }
}

/// Reads the first connectionClose frame from the outbound buffer. `hadClose` is true when a
/// close frame was found (even with no code); `code` is the 2-byte code or nil for empty payload.
/// `channel.isActive` is read after the frame is consumed.
private func outboundCloseResult(_ channel: EmbeddedChannel) throws -> (code: UInt16?, hadClose: Bool, active: Bool) {
    while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
        if frame.opcode == .connectionClose {
            var data = frame.unmaskedData
            let code = data.readInteger(as: UInt16.self)
            return (code, true, channel.isActive)
        }
    }
    return (nil, false, channel.isActive)
}

/// Returns every opcode found in the outbound buffer.
private func outboundOpcodes(_ channel: EmbeddedChannel) throws -> [WebSocketOpcode] {
    var opcodes: [WebSocketOpcode] = []
    while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
        opcodes.append(frame.opcode)
    }
    return opcodes
}

@Suite("WebSocketSessionHandler protocol checks (#810)")
struct WebSocketSessionHandlerProtocolTests {

    // MARK: - RSV bits (RFC 6455 §5.2)

    @Test("RSV1 set → close with 1002")
    func rsv1Rejected() throws {
        let channel = try makeSession()
        try channel.writeInbound(
            WebSocketFrame(fin: true, rsv1: true, opcode: .binary, data: ByteBuffer(string: "x")))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002)
        #expect(!r.active)
    }

    @Test("RSV2 set → close with 1002")
    func rsv2Rejected() throws {
        let channel = try makeSession()
        try channel.writeInbound(
            WebSocketFrame(fin: true, rsv2: true, opcode: .binary, data: ByteBuffer(string: "x")))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002)
        #expect(!r.active)
    }

    @Test("RSV3 set → close with 1002")
    func rsv3Rejected() throws {
        let channel = try makeSession()
        try channel.writeInbound(
            WebSocketFrame(fin: true, rsv3: true, opcode: .binary, data: ByteBuffer(string: "x")))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002)
        #expect(!r.active)
    }

    // MARK: - Reserved opcodes (RFC 6455 §5.2)

    @Test("Reserved non-control opcode → close with 1002", arguments: [UInt8(3), 4, 5, 6, 7])
    func reservedNonControlOpcode(rawValue: UInt8) throws {
        let channel = try makeSession()
        let opcode = try #require(WebSocketOpcode(encodedWebSocketOpcode: rawValue))
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: opcode, data: ByteBuffer()))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002, "opcode \(rawValue)")
        #expect(!r.active)
    }

    @Test("Reserved control opcode → close with 1002", arguments: [UInt8(11), 12, 13, 14, 15])
    func reservedControlOpcode(rawValue: UInt8) throws {
        let channel = try makeSession()
        let opcode = try #require(WebSocketOpcode(encodedWebSocketOpcode: rawValue))
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: opcode, data: ByteBuffer()))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002, "opcode \(rawValue)")
        #expect(!r.active)
    }

    // MARK: - Close frame validation (RFC 6455 §5.5.1, §7.4.2, §8.1)

    @Test("1-byte close payload → 1002")
    func oneByteClosePayload() throws {
        let channel = try makeSession()
        var buf = ByteBuffer()
        buf.writeInteger(UInt8(0))  // only 1 byte, not a valid 2-byte code
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: buf))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002)
        #expect(!r.active)
    }

    @Test(
        "Invalid close code → 1002",
        arguments: [UInt16(0), 1, 999, 1004, 1005, 1006, 1015, 1016, 2999, 5000]
    )
    func invalidCloseCode(code: UInt16) throws {
        let channel = try makeSession()
        var buf = ByteBuffer()
        buf.writeInteger(code)
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: buf))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002, "close code \(code) should be rejected with 1002")
        #expect(!r.active)
    }

    @Test(
        "Valid close code → reply with 1000",
        arguments: [UInt16(1000), 1003, 1007, 1011, 1012, 1014, 3000, 4999]
    )
    func validCloseCodeRepliedWith1000(code: UInt16) throws {
        let channel = try makeSession()
        var buf = ByteBuffer()
        buf.writeInteger(code)
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: buf))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1000, "valid code \(code) should be replied with 1000, not echoed")
        #expect(!r.active)
    }

    @Test("Close reason with invalid UTF-8 → 1007")
    func invalidUTF8CloseReason() throws {
        let channel = try makeSession()
        var buf = ByteBuffer()
        buf.writeInteger(UInt16(1000))       // valid code
        buf.writeBytes([0xFF, 0xFE, 0x80])  // invalid UTF-8
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: buf))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1007)
        #expect(!r.active)
    }

    @Test("Valid close (code 1001 + UTF-8 reason) → reply with 1000")
    func validCloseRepliedWith1000() throws {
        let channel = try makeSession()
        var buf = ByteBuffer()
        buf.writeInteger(UInt16(1001))  // valid code: going away
        buf.writeString("going away")   // valid UTF-8 reason
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: buf))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1000, "valid close should be replied with 1000, not echoed")
        #expect(!r.active)
    }

    @Test("Empty close payload → reply with empty close (no code)")
    func emptyClosePayload() throws {
        let channel = try makeSession()
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer()))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.hadClose, "should reply with a close frame")
        #expect(r.code == nil, "empty close should reply with no code")
        #expect(!r.active)
    }

    // MARK: - Trailing frames after a protocol failure (RFC 6455 §7.1.7)

    @Test("RSV failure: trailing ping and data are dropped, only one Close sent, cause is error")
    func rsvFailureDropsTrailingFrames() async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let (channel, handler) = try makeSessionWithHandler("proto-rsv-trail", transport: transport)

        // Buffer a fragment so we can verify it is cleared.
        try channel.writeInbound(
            WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(string: "fragment")))

        // RSV failure.
        try channel.writeInbound(
            WebSocketFrame(fin: true, rsv1: true, opcode: .binary, data: ByteBuffer(string: "bad")))

        // Trailing frames that must be dropped: a ping (control) and a continuation of the
        // buffered fragment (data reassembler path).
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()))
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(string: "after")))

        channel.embeddedEventLoop.run()

        let opcodes = try outboundOpcodes(channel)
        #expect(opcodes == [.connectionClose], "expected exactly one close frame, got \(opcodes)")
        #expect(!opcodes.contains(.pong), "ping after failure must not be answered with a pong")
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)

        // No data must reach the transport after a protocol failure.
        await handler.waitForInboundIdle()
        #expect(recorder.messages.isEmpty, "no message must reach the transport after a protocol failure")
    }

    @Test("Reserved opcode failure: trailing ping and data are dropped, only one Close sent, cause is error")
    func opcodeFailureDropsTrailingFrames() async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let (channel, handler) = try makeSessionWithHandler("proto-opcode-trail", transport: transport)
        let reserved = try #require(WebSocketOpcode(encodedWebSocketOpcode: 3))

        // Buffer a fragment.
        try channel.writeInbound(
            WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(string: "fragment")))

        // Reserved opcode failure.
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: reserved, data: ByteBuffer()))

        // Trailing frames that must be dropped: a ping (control) and a continuation of the
        // buffered fragment (data reassembler path).
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()))
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(string: "after")))

        channel.embeddedEventLoop.run()

        let opcodes = try outboundOpcodes(channel)
        #expect(opcodes == [.connectionClose], "expected exactly one close frame, got \(opcodes)")
        #expect(!opcodes.contains(.pong))
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)

        // No data must reach the transport after a protocol failure.
        await handler.waitForInboundIdle()
        #expect(recorder.messages.isEmpty, "no message must reach the transport after a protocol failure")
    }

    // MARK: - Bad fragment sequences (RFC 6455 §5.4, #822)

    /// Writes `frames`, then a trailing ping and a whole binary message, and checks that the
    /// connection failed with 1002 and that nothing after the failure was answered or delivered.
    private func expectBadFragmentSequence(_ frames: [WebSocketFrame], sessionID: String) async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let (channel, handler) = try makeSessionWithHandler(sessionID, transport: transport)

        for frame in frames {
            try channel.writeInbound(frame)
        }
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(string: "after")))
        channel.embeddedEventLoop.run()

        var closeCode: UInt16?
        var opcodes: [WebSocketOpcode] = []
        while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
            opcodes.append(frame.opcode)
            if frame.opcode == .connectionClose {
                var data = frame.unmaskedData
                closeCode = data.readInteger(as: UInt16.self)
            }
        }
        #expect(opcodes == [.connectionClose], "expected exactly one close frame, got \(opcodes)")
        #expect(closeCode == 1002)
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)

        await handler.waitForInboundIdle()
        #expect(recorder.messages.isEmpty, "no message must reach the transport from a bad fragment sequence")
    }

    @Test("Continuation with nothing to continue → 1002, trailing frames dropped", arguments: [true, false])
    func orphanContinuationFails(fin: Bool) async throws {
        try await expectBadFragmentSequence(
            [WebSocketFrame(fin: fin, opcode: .continuation, data: ByteBuffer(string: "orphan"))],
            sessionID: "proto-orphan-\(fin)"
        )
    }

    @Test("New opener while a message is unfinished → 1002, neither message delivered", arguments: [true, false])
    func openerMidMessageFails(fin: Bool) async throws {
        // Autobahn 5.18 is the fin=true case: two fragments that both carry the text opcode.
        try await expectBadFragmentSequence(
            [
                WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(string: "first")),
                WebSocketFrame(fin: fin, opcode: .text, data: ByteBuffer(string: "second")),
            ],
            sessionID: "proto-opener-\(fin)"
        )
    }

    @Test("Bad close: trailing ping is dropped after the error close")
    func badCloseDropsTrailingPing() throws {
        let channel = try makeSession("proto-badclose-trail")

        // 1-byte close payload → protocol error.
        var buf = ByteBuffer()
        buf.writeInteger(UInt8(0))
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .connectionClose, data: buf))

        // Trailing ping after the connection is failed.
        try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()))

        channel.embeddedEventLoop.run()

        let opcodes = try outboundOpcodes(channel)
        #expect(opcodes == [.connectionClose], "expected exactly one close frame, got \(opcodes)")
        #expect(!opcodes.contains(.pong))
        #expect(!channel.isActive)
    }
}
