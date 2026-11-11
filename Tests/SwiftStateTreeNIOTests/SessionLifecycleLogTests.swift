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

    /// Every line, in order, `sessionOpened` included.
    var allRecords: [SessionLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored.map { try! JSONDecoder().decode(SessionLifecycleRecord.self, from: Data($0.utf8)) }
    }

    /// The lines after a session's `sessionOpened`: what the tests of closes and joins compare.
    var records: [SessionLifecycleRecord] {
        allRecords.filter { $0.event != .sessionOpened }
    }

    /// The `sessionOpened` lines.
    var opened: [SessionLifecycleRecord] {
        allRecords.filter { $0.event == .sessionOpened }
    }

    /// The raw JSON lines.
    var rawLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func makeSession(
    _ id: String,
    lines: SessionLines,
    pongTimeout: TimeAmount = .seconds(5),
    transport: WebSocketTransport = WebSocketTransport()
) throws -> (EmbeddedChannel, WebSocketSessionHandler) {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(id),
        path: "/test",
        transport: transport,
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

/// Holds `onMessage` until `release()`, then writes `sessionJoined` to `lines` for the session:
/// a stand-in for a land whose join, read before the close, completes after it.
private final class HeldJoinDelegate: TransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    let lines: SessionLines
    init(lines: SessionLines) { self.lines = lines }

    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }

    func release() {
        lock.lock()
        released = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {}
    func onMessage(_ message: Data, from sessionID: SessionID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started = true
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
        lines.log.logSessionJoined(sessionID: sessionID, playerID: PlayerID("p"), landID: "t:room", instance: 1)
    }
}

private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

extension SessionLifecycleLogTests {
    @Test("A close decided while a join read before it is still held is logged first; both lines carry the sessionID")
    func closeBeforeHeldJoin() async throws {
        let lines = SessionLines()
        let delegate = HeldJoinDelegate(lines: lines)
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)
        let (channel, _) = try makeSession("held-join", lines: lines, transport: transport)
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: "join")))
        channel.embeddedEventLoop.run()
        try #require(await waitUntil { delegate.hasStarted }, "the join reached the land and is held")

        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer()))
        #expect(lines.records.map(\.event) == [.sessionClosed], "the close is logged while the join is held")

        delegate.release()
        #expect(await waitUntil { lines.records.count == 2 })
        _ = try? channel.finish()
        #expect(lines.records.map(\.event) == [.sessionClosed, .sessionJoined])
        #expect(Set(lines.records.map(\.sessionID)) == ["held-join"], "paired by sessionID, in either order")
    }

    @Test("connectionLost is recorded when the channel goes inactive: a close queued before removal doesn't take it")
    func inactiveThenQueuedClose() throws {
        let lines = SessionLines()
        let (channel, handler) = try makeSession("gap-session", lines: lines)
        // The channel is gone, but the handler is removed only on a later tick; a transport
        // close arriving in that gap must not become the cause.
        channel.pipeline.fireChannelInactive()
        #expect(lines.records.map(\.cause) == [.connectionLost], "recorded at inactive, not at removal")
        handler.close(code: .policyViolation)
        #expect(try channel.readOutbound(as: WebSocketFrame.self) == nil, "no close frame for a gone channel")
        _ = try? channel.finish()
        #expect(lines.records.map(\.cause) == [.connectionLost])
    }

    @Test("A pong deadline due after the channel went inactive doesn't take the cause")
    func inactiveThenPongDeadline() throws {
        let lines = SessionLines()
        let id = "gap-pong"
        let (channel, _) = try makeSession(id, lines: lines)
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID(id)))
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.advanceTime(by: .seconds(5))
        _ = try? channel.finish()
        #expect(lines.records.map(\.cause) == [.connectionLost])
    }

    @Test("errorCaught: a reset or a broken pipe is connectionLost, another error is error")
    func errorCauses() throws {
        struct DecodeFailure: Error {}
        for (error, cause) in [
            (IOError(errnoCode: ECONNRESET, reason: "read") as Error, SessionCloseCause.connectionLost),
            (IOError(errnoCode: EPIPE, reason: "write") as Error, SessionCloseCause.connectionLost),
            (DecodeFailure() as Error, SessionCloseCause.error),
        ] {
            let lines = SessionLines()
            let (channel, _) = try makeSession("error-session", lines: lines)
            channel.pipeline.fireErrorCaught(error)
            _ = try? channel.finish()
            #expect(lines.records.map(\.cause) == [cause], "\(error)")
        }
    }
}

/// The session's first line (#490): `sessionOpened`, with the peer when the channel knows it.
extension SessionLifecycleLogTests {
    @Test("sessionOpened is the session's first line, once, with the peer's address and port")
    func openedFirstWithPeer() throws {
        let lines = SessionLines()
        let (channel, handler) = try makeSession("opened-session", lines: lines)
        handler.close(code: .policyViolation)
        _ = try? channel.finish()
        #expect(lines.allRecords.map(\.event) == [.sessionOpened, .sessionClosed])
        let opened = try #require(lines.opened.first)
        #expect(opened.sessionID == "opened-session")
        #expect(opened.peerHost == "127.0.0.1")
        #expect(opened.peerPort == 1)
        let line = try #require(lines.rawLines.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["event", "sessionID", "peerHost", "peerPort", "wallMs", "uptimeNs"])
        #expect(object["peerPort"] as? Int == 1)
    }

    @Test("Without a remote address, sessionOpened has no peer fields")
    func openedWithoutPeer() throws {
        let lines = SessionLines()
        let channel = EmbeddedChannel()
        #expect(channel.remoteAddress == nil)
        let handler = WebSocketSessionHandler(
            sessionID: SessionID("no-peer"),
            path: "/test",
            transport: WebSocketTransport(),
            eventLoop: channel.eventLoop,
            lifecycleLog: lines.log,
            logger: Logger(label: "test")
        )
        try channel.pipeline.syncOperations.addHandler(handler)
        _ = try? channel.finish()
        let line = try #require(lines.rawLines.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["event"] as? String == "sessionOpened")
        #expect(object["peerHost"] == nil)
        #expect(object["peerPort"] == nil)
    }

    @Test("A sync-lag close that reaches a session whose pong timeout was decided first doesn't take the cause")
    func pongTimeoutThenLagClose() throws {
        let lines = SessionLines()
        let id = "pong-then-lag"
        let (channel, handler) = try makeSession(id, lines: lines)
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID(id)))
        channel.embeddedEventLoop.advanceTime(by: .seconds(5))
        // The transport's close for a lag close decided before the pong timeout, arriving after it.
        handler.close(code: WebSocketErrorCode(codeNumber: Int(SessionClose.Code.unresponsive)), reason: "unresponsive")
        _ = try? channel.finish()
        #expect(lines.records.map(\.cause) == [.pongTimeout])
        #expect(lines.records.map(\.code) == [1001], "no 4011 line: the first cause stands")
    }
}
