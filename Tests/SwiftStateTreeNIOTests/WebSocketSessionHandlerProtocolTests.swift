// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerProtocolTests.swift
// Tests for RFC 6455 protocol enforcement: RSV bits, reserved opcodes, close validation (#810),
// bad fragment sequences and oversized fragmented messages (#822).

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

/// Records messages and disconnects delivered to the transport, in order (thread-safe).
private final class RecordingDelegate: TransportDelegate, @unchecked Sendable {
    enum Event: Equatable {
        case message(Data)
        case disconnect
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    var events: [Event] { lock.withLock { recorded } }
    var messages: [Data] {
        events.compactMap { if case .message(let data) = $0 { data } else { nil } }
    }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        lock.withLock { recorded.append(.disconnect) }
    }
    func onMessage(_ data: Data, from sessionID: SessionID) async {
        lock.withLock { recorded.append(.message(data)) }
    }
}

/// Holds flushes while `holding`, so the handler's close frame stays unwritten until released.
private final class FlushHold: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = WebSocketFrame
    var holding = true
    func flush(context: ChannelHandlerContext) {
        if !holding { context.flush() }
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
            WebSocketFrame.client(fin: true, rsv1: true, opcode: .binary, data: ByteBuffer(string: "x")))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002)
        #expect(!r.active)
    }

    @Test("RSV2 set → close with 1002")
    func rsv2Rejected() throws {
        let channel = try makeSession()
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, rsv2: true, opcode: .binary, data: ByteBuffer(string: "x")))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1002)
        #expect(!r.active)
    }

    @Test("RSV3 set → close with 1002")
    func rsv3Rejected() throws {
        let channel = try makeSession()
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, rsv3: true, opcode: .binary, data: ByteBuffer(string: "x")))
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
            WebSocketFrame.client(fin: true, opcode: opcode, data: ByteBuffer()))
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
            WebSocketFrame.client(fin: true, opcode: opcode, data: ByteBuffer()))
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
            WebSocketFrame.client(fin: true, opcode: .connectionClose, data: buf))
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
            WebSocketFrame.client(fin: true, opcode: .connectionClose, data: buf))
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
            WebSocketFrame.client(fin: true, opcode: .connectionClose, data: buf))
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
            WebSocketFrame.client(fin: true, opcode: .connectionClose, data: buf))
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
            WebSocketFrame.client(fin: true, opcode: .connectionClose, data: buf))
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == 1000, "valid close should be replied with 1000, not echoed")
        #expect(!r.active)
    }

    @Test("Empty close payload → reply with empty close (no code)")
    func emptyClosePayload() throws {
        let channel = try makeSession()
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: .connectionClose, data: ByteBuffer()))
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
            WebSocketFrame.client(fin: false, opcode: .binary, data: ByteBuffer(string: "fragment")))

        // RSV failure.
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, rsv1: true, opcode: .binary, data: ByteBuffer(string: "bad")))

        // Trailing frames that must be dropped: a ping (control) and a continuation of the
        // buffered fragment (data reassembler path).
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: .ping, data: ByteBuffer()))
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: .continuation, data: ByteBuffer(string: "after")))

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
            WebSocketFrame.client(fin: false, opcode: .binary, data: ByteBuffer(string: "fragment")))

        // Reserved opcode failure.
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: reserved, data: ByteBuffer()))

        // Trailing frames that must be dropped: a ping (control) and a continuation of the
        // buffered fragment (data reassembler path).
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: .ping, data: ByteBuffer()))
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: .continuation, data: ByteBuffer(string: "after")))

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

    // MARK: - Bad fragment sequences (RFC 6455 §5.4) and oversized messages (§7.4.1), #822

    /// Writes a complete message, then `frames`, then a trailing ping, continuation and whole
    /// binary message, with the close frame's write held. Checks that the earlier message and
    /// then the disconnect reach the transport while the close write is still pending (the
    /// handler doesn't wait for it), and once released, that the connection failed with `code`
    /// and nothing after the failure was answered or delivered.
    private func expectFailure(_ frames: [WebSocketFrame], code: UInt16, sessionID: String) async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        let hold = FlushHold()
        let handler = WebSocketSessionHandler(
            sessionID: SessionID(sessionID),
            path: "/test",
            transport: transport,
            eventLoop: channel.eventLoop,
            logger: Logger(label: "test")
        )
        // Outbound order: handler → hold → channel.
        try channel.pipeline.syncOperations.addHandler(hold)
        try channel.pipeline.syncOperations.addHandler(handler)

        let before = Data("before".utf8)
        try channel.writeInbound(WebSocketFrame.client(fin: true, opcode: .binary, data: ByteBuffer(bytes: before)))
        for frame in frames {
            try channel.writeInbound(frame)
        }
        channel.embeddedEventLoop.run()

        // The close frame isn't written yet, so the channel hasn't closed: the disconnect came
        // from the failure itself, not from a trailing orphan continuation.
        await handler.waitForInboundIdle()
        #expect(channel.isActive, "the close write is held")
        #expect(recorder.events == [.message(before), .disconnect], "\(recorder.events)")

        try channel.writeInbound(WebSocketFrame.client(fin: true, opcode: .ping, data: ByteBuffer()))
        try channel.writeInbound(WebSocketFrame.client(fin: true, opcode: .continuation, data: ByteBuffer(string: "after")))
        try channel.writeInbound(WebSocketFrame.client(fin: true, opcode: .binary, data: ByteBuffer(string: "after")))
        channel.embeddedEventLoop.run()

        hold.holding = false
        channel.flush()
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
        #expect(closeCode == code)
        #expect(!channel.isActive)
        #expect(handler.closeCause == .error)

        await handler.waitForInboundIdle()
        #expect(recorder.events == [.message(before), .disconnect], "nothing after the failure is delivered: \(recorder.events)")
    }

    @Test("Continuation with nothing to continue → 1002, trailing frames dropped", arguments: [true, false])
    func orphanContinuationFails(fin: Bool) async throws {
        try await expectFailure(
            [WebSocketFrame.client(fin: fin, opcode: .continuation, data: ByteBuffer(string: "orphan"))],
            code: 1002,
            sessionID: "proto-orphan-\(fin)"
        )
    }

    @Test("New opener while a message is unfinished → 1002, neither message delivered", arguments: [
        (WebSocketOpcode.text, WebSocketOpcode.text, true),
        (.text, .text, false),
        (.text, .binary, true),
        (.binary, .text, false),
    ])
    func openerMidMessageFails(first: WebSocketOpcode, opener: WebSocketOpcode, fin: Bool) async throws {
        // Autobahn 5.18 is text, text, fin=true: two fragments that both carry the text opcode.
        try await expectFailure(
            [
                WebSocketFrame.client(fin: false, opcode: first, data: ByteBuffer(string: "first")),
                WebSocketFrame.client(fin: fin, opcode: opener, data: ByteBuffer(string: "second")),
            ],
            code: 1002,
            sessionID: "proto-opener-\(first)-\(opener)-\(fin)"
        )
    }

    /// `count` bytes of a fragment.
    private func fragment(_ opcode: WebSocketOpcode, fin: Bool, count: Int) -> WebSocketFrame {
        WebSocketFrame.client(fin: fin, opcode: opcode, data: ByteBuffer(bytes: [UInt8](repeating: 0x61, count: count)))
    }

    @Test("A fragmented message past the reassembly limit → 1009, never 1002: an oversized first fragment, its continuation follows")
    func oversizedOpenerFails() async throws {
        let limit = WebSocketFragmentReassembler.maxFragmentSize
        try await expectFailure(
            [fragment(.binary, fin: false, count: limit + 1), fragment(.continuation, fin: true, count: 1)],
            code: 1009,
            sessionID: "proto-oversize-opener"
        )
    }

    @Test("A fragmented message past the reassembly limit → 1009, never 1002: crossed mid-message, a continuation follows")
    func oversizedMidMessageFails() async throws {
        let limit = WebSocketFragmentReassembler.maxFragmentSize
        try await expectFailure(
            [
                fragment(.text, fin: false, count: limit - 10),
                fragment(.continuation, fin: false, count: 20),
                fragment(.continuation, fin: true, count: 1),
            ],
            code: 1009,
            sessionID: "proto-oversize-mid"
        )
    }

    @Test("A fragmented message past the reassembly limit → 1009, never dropped silently: crossed on the final fragment")
    func oversizedFinalFragmentFails() async throws {
        let limit = WebSocketFragmentReassembler.maxFragmentSize
        try await expectFailure(
            [fragment(.binary, fin: false, count: limit - 10), fragment(.continuation, fin: true, count: 20)],
            code: 1009,
            sessionID: "proto-oversize-final"
        )
    }

    @Test("Invalid UTF-8 in a fragmented text message → 1007, through the same failure")
    func invalidUTF8Fails() async throws {
        try await expectFailure(
            [
                WebSocketFrame.client(fin: false, opcode: .text, data: ByteBuffer(bytes: [0x61, 0xC3])),
                WebSocketFrame.client(fin: true, opcode: .continuation, data: ByteBuffer(bytes: [0x28])),
            ],
            code: 1007,
            sessionID: "proto-utf8"
        )
    }

    // MARK: - Close frame validation (RFC 6455 §5.5.1, §7.4.2, §8.1), #827

    /// Sends a single malformed close frame with the flush held, then checks that the disconnect
    /// arrives (from the failure path itself, not from the channel closing) and that `closeCause`
    /// is `.error` — not `.serverClose`, which the old `closeOnLoop + enqueueDisconnect` path set.
    private func expectCloseValidationFailure(
        payload: ByteBuffer,
        code expectedCode: UInt16,
        sessionID: String
    ) async throws {
        let recorder = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(recorder)
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        let hold = FlushHold()
        let handler = WebSocketSessionHandler(
            sessionID: SessionID(sessionID),
            path: "/test",
            transport: transport,
            eventLoop: channel.eventLoop,
            logger: Logger(label: "test")
        )
        try channel.pipeline.syncOperations.addHandler(hold)
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.writeInbound(WebSocketFrame.client(fin: true, opcode: .connectionClose, data: payload))
        channel.embeddedEventLoop.run()
        await handler.waitForInboundIdle()
        #expect(channel.isActive, "the close write is held")
        #expect(handler.closeCause == .error, "malformed close is a protocol error, not server close: \(String(describing: handler.closeCause))")
        #expect(recorder.events == [.disconnect], "\(recorder.events)")
        hold.holding = false
        channel.flush()
        channel.embeddedEventLoop.run()
        let r = try outboundCloseResult(channel)
        #expect(r.code == expectedCode)
        #expect(!r.active)
    }

    @Test("1-byte close payload → 1002, cause .error, disconnect before frame written")
    func oneByteClosePayloadCausesError() async throws {
        var buf = ByteBuffer()
        buf.writeInteger(UInt8(0))
        try await expectCloseValidationFailure(payload: buf, code: 1002, sessionID: "proto-malclose-1b")
    }

    @Test("Invalid close code → 1002, cause .error, disconnect before frame written")
    func invalidCloseCodeCausesError() async throws {
        var buf = ByteBuffer()
        buf.writeInteger(UInt16(1005))
        try await expectCloseValidationFailure(payload: buf, code: 1002, sessionID: "proto-malclose-code")
    }

    @Test("Invalid UTF-8 close reason → 1007, cause .error, disconnect before frame written")
    func invalidUTF8CloseReasonCausesError() async throws {
        var buf = ByteBuffer()
        buf.writeInteger(UInt16(1000))
        buf.writeBytes([0xC3, 0x28])
        try await expectCloseValidationFailure(payload: buf, code: 1007, sessionID: "proto-malclose-utf8")
    }

    @Test("Bad close: trailing ping is dropped after the error close")
    func badCloseDropsTrailingPing() throws {
        let channel = try makeSession("proto-badclose-trail")

        // 1-byte close payload → protocol error.
        var buf = ByteBuffer()
        buf.writeInteger(UInt8(0))
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: .connectionClose, data: buf))

        // Trailing ping after the connection is failed.
        try channel.writeInbound(
            WebSocketFrame.client(fin: true, opcode: .ping, data: ByteBuffer()))

        channel.embeddedEventLoop.run()

        let opcodes = try outboundOpcodes(channel)
        #expect(opcodes == [.connectionClose], "expected exactly one close frame, got \(opcodes)")
        #expect(!opcodes.contains(.pong))
        #expect(!channel.isActive)
    }
}
