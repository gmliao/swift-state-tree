// Tests/SwiftStateTreeNIOTests/SessionLifecycleLogTests.swift
//
// The session handler's `sessionClosed` line in the lifecycle log: one line per session, with
// the cause decided first (pong timeout, client close, server close, or a lost connection).

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

/// A lifecycle log that keeps its session lines in memory.
final class SessionLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private(set) lazy var log = LandLifecycleLog(write: { [unowned self] line in
        self.lock.lock()
        self.stored.append(line)
        self.lock.unlock()
    })

    var records: [SessionLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored.map { try! JSONDecoder().decode(SessionLifecycleRecord.self, from: Data($0.utf8)) }
    }
}

private func makeSession(_ id: String, lines: SessionLines, pongTimeout: TimeAmount = .seconds(5)) throws -> (EmbeddedChannel, WebSocketSessionHandler) {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(id),
        path: "/test",
        transport: WebSocketTransport(),
        eventLoop: channel.eventLoop,
        pongTimeout: pongTimeout,
        lifecycleLog: lines.log,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(handler)
    return (channel, handler)
}

@Suite("Session lifecycle log (sessionClosed)")
struct SessionLifecycleLogTests {
    @Test("A pong timeout logs pongTimeout with 1001, and nothing more when the channel then closes")
    func pongTimeout() throws {
        let lines = SessionLines()
        let id = "pong-session"
        let (channel, _) = try makeSession(id, lines: lines)
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID(id)))
        channel.embeddedEventLoop.advanceTime(by: .seconds(5))
        _ = try? channel.finish()
        #expect(lines.records.map(\.cause) == [.pongTimeout])
        #expect(lines.records.first?.code == 1001)
        #expect(lines.records.first?.event == .sessionClosed)
        #expect(lines.records.first?.sessionID == id)
    }

    @Test("A client close frame logs clientClose with the client's code")
    func clientClose() throws {
        let lines = SessionLines()
        let (channel, _) = try makeSession("client-session", lines: lines)
        var payload = ByteBuffer()
        payload.write(webSocketErrorCode: WebSocketErrorCode(codeNumber: 4321))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))
        _ = try? channel.finish()
        #expect(lines.records.map(\.cause) == [.clientClose])
        #expect(lines.records.first?.code == 4321)
    }

    @Test("A server close requested through the handler logs serverClose with its code")
    func serverClose() throws {
        let lines = SessionLines()
        let (channel, handler) = try makeSession("server-session", lines: lines)
        handler.close(code: .policyViolation)
        // The client answers the close frame: no second line.
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer()))
        _ = try? channel.finish()
        #expect(lines.records.map(\.cause) == [.serverClose])
        #expect(lines.records.first?.code == 1008)
    }

    @Test("A channel that goes away with no close decided logs connectionLost, no code")
    func connectionLost() throws {
        let lines = SessionLines()
        let (channel, handler) = try makeSession("lost-session", lines: lines)
        channel.pipeline.fireChannelInactive()
        _ = try? channel.finish()
        #expect(lines.records.map(\.cause) == [.connectionLost])
        #expect(lines.records.first?.code == nil)
        #expect(handler.closeCause == .connectionLost)
    }

    @Test("Without a log, the handler writes nothing (the default when LAND_LIFECYCLE_LOG_PATH is unset)")
    func offByDefault() throws {
        #expect(LandLifecycleLog.shared == nil, "tests run without LAND_LIFECYCLE_LOG_PATH")
    }
}
