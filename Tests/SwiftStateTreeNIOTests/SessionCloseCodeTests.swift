// Tests/SwiftStateTreeNIOTests/SessionCloseCodeTests.swift
//
// A server-side close with an application code and reason (#332): the transport passes it to
// the connection, and the NIO handler writes it in the close frame.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

private actor RecordingConnection: WebSocketConnection {
    private(set) var closes: [SessionClose?] = []
    func send(_ data: Data) async throws {}
    func close() async throws { closes.append(nil) }
    func close(with close: SessionClose) async throws { closes.append(close) }
}

/// A connection without its own `close(with:)`: the protocol's default.
private actor PlainConnection: WebSocketConnection {
    private(set) var closes = 0
    func send(_ data: Data) async throws {}
    func close() async throws { closes += 1 }
}

private func closeFrameBytes(code: WebSocketErrorCode, reason: String) throws -> [UInt8] {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    let sessionID = SessionID("s1")
    let handler = WebSocketSessionHandler(
        sessionID: sessionID,
        path: "/test",
        transport: WebSocketTransport(),
        eventLoop: channel.eventLoop,
        lifecycleLog: nil,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
    try channel.pipeline.syncOperations.addHandler(handler)
    handler.close(code: code, reason: reason)
    var bytes: [UInt8] = []
    while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
        bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
    }
    _ = try? channel.finish()
    return bytes
}

@Suite("Server close with an application code (#332)")
struct SessionCloseCodeTests {
    @Test("The transport hands the code and reason to the connection; a plain close stays a plain close")
    func transportPassesTheCode() async throws {
        let transport = WebSocketTransport()
        let connection = RecordingConnection()
        _ = await transport.handleConnection(sessionID: SessionID("a"), connection: connection)
        await transport.closeSession(SessionID("a"), with: SessionClose(code: SessionClose.Code.resync, reason: "resync:abc"))
        #expect(await connection.closes == [SessionClose(code: 4009, reason: "resync:abc")])

        let other = RecordingConnection()
        _ = await transport.handleConnection(sessionID: SessionID("b"), connection: other)
        await transport.closeSession(SessionID("b"))
        #expect(await other.closes == [nil])
    }

    @Test("A connection without close(with:) is closed by the default")
    func defaultConnectionClose() async throws {
        let transport = WebSocketTransport()
        let connection = PlainConnection()
        _ = await transport.handleConnection(sessionID: SessionID("a"), connection: connection)
        await transport.closeSession(SessionID("a"), with: SessionClose(code: SessionClose.Code.slowConsumer))
        #expect(await connection.closes == 1)
    }

    @Test("The handler writes the code and the reason in the close frame")
    func handlerWritesCodeAndReason() throws {
        let bytes = try closeFrameBytes(code: WebSocketErrorCode(codeNumber: 4009), reason: "resync:ab")
        // FIN + close opcode, length 2 + 9, status 4009 (0x0FA9), then the reason.
        #expect(bytes.suffix(13) == [0x88, 0x0B, 0x0F, 0xA9] + Array("resync:ab".utf8))
        #expect(try closeFrameBytes(code: .normalClosure, reason: "").suffix(4) == [0x88, 0x02, 0x03, 0xE8])
    }

    @Test("A reason is cut to 123 UTF-8 bytes at a character boundary")
    func reasonTruncation() {
        #expect(SessionClose(code: 4009, reason: String(repeating: "a", count: 200)).reason.utf8.count == 123)
        // 41 three-byte characters are 123 bytes; a 42nd doesn't fit.
        let wide = SessionClose(code: 4009, reason: String(repeating: "界", count: 42)).reason
        #expect(wide.utf8.count == 123)
        #expect(wide == String(repeating: "界", count: 41))
    }
}
