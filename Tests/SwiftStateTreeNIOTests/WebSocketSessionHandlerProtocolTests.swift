// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerProtocolTests.swift
// Tests for RFC 6455 protocol enforcement: RSV bits, reserved opcodes, close validation (#810).

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

private func makeSession(_ sessionID: String = "proto-s1") throws -> EmbeddedChannel {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(sessionID),
        path: "/test",
        transport: WebSocketTransport(),
        eventLoop: channel.eventLoop,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(handler)
    return channel
}

/// Reads the first connectionClose frame from the outbound buffer and returns its close code (nil
/// for an empty close payload). `channel.isActive` is read after the frame is consumed.
private func outboundCloseResult(_ channel: EmbeddedChannel) throws -> (code: UInt16?, active: Bool) {
    while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
        if frame.opcode == .connectionClose {
            var data = frame.unmaskedData
            let code = data.readInteger(as: UInt16.self)
            return (code, channel.isActive)
        }
    }
    return (nil, channel.isActive)
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
        arguments: [UInt16(0), 1, 999, 1004, 1005, 1006, 1015, 1016, 2999]
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
        #expect(r.code == nil, "empty close should reply with no code")
        #expect(!r.active)
    }
}
