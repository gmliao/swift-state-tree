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
    @Test("NIOLandServerConfiguration.syncLag turns on syncSequence in the land's encoding; an explicit value replaces the environment's")
    func serverConfigurationSyncLag() {
        var configuration = NIOLandServerConfiguration(transportEncoding: .messagepack, syncLag: SyncLagPolicy())
        #expect(!configuration.effectiveTransportEncoding.syncSequence)
        configuration.syncLag = SyncLagPolicy(enabled: true, resyncAfter: .seconds(5))
        #expect(configuration.effectiveTransportEncoding.syncSequence)
        #expect(configuration.effectiveTransportEncoding.stateUpdateFeatures.contains(StateUpdateFeature.syncSequence))
        #expect(configuration.syncLag.resyncAfter == .seconds(5))
    }

    @Test("A close for an older connection generation leaves a newer connection under the same session open")
    func generationGuardedClose() async throws {
        let transport = WebSocketTransport()
        let old = RecordingConnection()
        _ = await transport.handleConnection(sessionID: SessionID("g"), connection: old)
        let oldGeneration = try #require(await transport.connectionGeneration(for: SessionID("g")))
        await transport.handleDisconnection(sessionID: SessionID("g"))
        let new = RecordingConnection()
        _ = await transport.handleConnection(sessionID: SessionID("g"), connection: new)
        let close = SessionClose(code: SessionClose.Code.unresponsive, reason: "unresponsive")
        await transport.closeSession(SessionID("g"), with: close, generation: oldGeneration)
        #expect(await new.closes.isEmpty)
        let current = await transport.connectionGeneration(for: SessionID("g"))
        await transport.closeSession(SessionID("g"), with: close, generation: current)
        #expect(await new.closes == [close])
    }

    @Test("The transport hands the code and reason to the connection; a plain close stays a plain close")
    func transportPassesTheCode() async throws {
        let transport = WebSocketTransport()
        let connection = RecordingConnection()
        _ = await transport.handleConnection(sessionID: SessionID("a"), connection: connection)
        await transport.closeSession(SessionID("a"), with: SessionClose(code: SessionClose.Code.slowConsumer, reason: "slow consumer"))
        #expect(await connection.closes == [SessionClose(code: 4010, reason: "slow consumer")])

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
        let bytes = try closeFrameBytes(code: WebSocketErrorCode(codeNumber: 4010), reason: "slow:ab")
        // FIN + close opcode, length 2 + 7, status 4010 (0x0FAA), then the reason.
        #expect(bytes.suffix(11) == [0x88, 0x09, 0x0F, 0xAA] + Array("slow:ab".utf8))
        #expect(try closeFrameBytes(code: .normalClosure, reason: "").suffix(4) == [0x88, 0x02, 0x03, 0xE8])
    }

    @Test("A reason is cut to 123 UTF-8 bytes at a character boundary")
    func reasonTruncation() {
        #expect(SessionClose(code: 4010, reason: String(repeating: "a", count: 200)).reason.utf8.count == 123)
        // 41 three-byte characters are 123 bytes; a 42nd doesn't fit.
        let wide = SessionClose(code: 4010, reason: String(repeating: "界", count: 42)).reason
        #expect(wide.utf8.count == 123)
        #expect(wide == String(repeating: "界", count: 41))
    }
}
