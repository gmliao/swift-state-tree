// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerOrderTests.swift
//
// A session's connect, messages and disconnect reach the transport delegate in the order the
// channel saw them (#99). Before, each ran in its own Task: a join sent right after the upgrade
// could reach the router before the connection was registered, its "unknown session" error was
// dropped (no session queue yet), and the client waited for a join response forever.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

/// Records delegate calls; `onConnect` for a held session suspends until `release`.
private final class HoldingDelegate: TransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var held: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func hold(_ sessionID: String) {
        lock.lock()
        held.insert(sessionID)
        lock.unlock()
    }

    func release(_ sessionID: String) {
        lock.lock()
        held.remove(sessionID)
        let waiter = waiters.removeValue(forKey: sessionID)
        lock.unlock()
        waiter?.resume()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    private func record(_ event: String) {
        lock.lock()
        log.append(event)
        lock.unlock()
    }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {
        record("connect-start:\(sessionID.rawValue)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held.contains(sessionID.rawValue) {
                waiters[sessionID.rawValue] = continuation
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
        record("connect:\(sessionID.rawValue)")
    }

    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        record("disconnect:\(sessionID.rawValue)")
    }

    func onMessage(_ message: Data, from sessionID: SessionID) async {
        record("message:\(sessionID.rawValue):\(String(decoding: message, as: UTF8.self))")
    }
}

@discardableResult
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func makeSession(
    _ sessionID: String,
    transport: WebSocketTransport
) throws -> EmbeddedChannel {
    let channel = EmbeddedChannel()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(sessionID),
        path: "/test",
        transport: transport,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(handler)
    return channel
}

private func sendText(_ text: String, on channel: EmbeddedChannel) throws {
    let frame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text))
    try channel.writeInbound(frame)
    // The handler flushes its batch from a task on the event loop.
    channel.embeddedEventLoop.run()
}

@Suite("WebSocketSessionHandler inbound order")
struct WebSocketSessionHandlerOrderTests {
    @Test("Messages and the disconnect wait for a connect that has not finished")
    func messagesAndDisconnectWaitForConnect() async throws {
        let delegate = HoldingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)
        delegate.hold("s1")

        let channel = try makeSession("s1", transport: transport)
        await waitUntil { delegate.events.contains("connect-start:s1") }
        try sendText("join", on: channel)
        try sendText("action", on: channel)
        _ = try? channel.finish()

        // The connect is still held: nothing after it may have reached the delegate.
        try await Task.sleep(for: .milliseconds(100))
        #expect(delegate.events == ["connect-start:s1"])

        delegate.release("s1")
        await waitUntil { delegate.events.contains("disconnect:s1") }
        #expect(delegate.events == [
            "connect-start:s1",
            "connect:s1",
            "message:s1:join",
            "message:s1:action",
            "disconnect:s1",
        ])
    }

    @Test("A session held in its connect does not hold up other sessions")
    func otherSessionsStayConcurrent() async throws {
        let delegate = HoldingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)
        delegate.hold("s1")

        let held = try makeSession("s1", transport: transport)
        await waitUntil { delegate.events.contains("connect-start:s1") }
        let other = try makeSession("s2", transport: transport)
        try sendText("join", on: other)
        await waitUntil { delegate.events.contains("message:s2:join") }
        #expect(delegate.events.contains("connect:s2"))
        #expect(delegate.events.contains("message:s2:join"))
        #expect(!delegate.events.contains("connect:s1"))

        delegate.release("s1")
        _ = try? held.finish()
        _ = try? other.finish()
        let bothDisconnected = await waitUntil {
            delegate.events.contains("disconnect:s1") && delegate.events.contains("disconnect:s2")
        }
        #expect(bothDisconnected)
    }

    @Test("A message read in the same event-loop turn as the close frame precedes the disconnect")
    func messageInSameTurnAsCloseComesFirst() async throws {
        let delegate = HoldingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)

        let channel = try makeSession("s1", transport: transport)
        await waitUntil { delegate.events.contains("connect:s1") }
        // No loop run between the two frames: the message's batch flush is still scheduled
        // when the close frame arrives.
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: "last-action")))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer()))
        channel.embeddedEventLoop.run()

        let disconnected = await waitUntil { delegate.events.contains("disconnect:s1") }
        #expect(disconnected)
        #expect(delegate.events == ["connect-start:s1", "connect:s1", "message:s1:last-action", "disconnect:s1"])
    }

    @Test("A data frame read after the close frame does not reach the transport")
    func dataAfterCloseIsDropped() async throws {
        let delegate = HoldingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)

        let channel = try makeSession("s1", transport: transport)
        await waitUntil { delegate.events.contains("connect:s1") }
        // Both frames in one read: the pipeline delivers them back to back.
        channel.pipeline.fireChannelRead(NIOAny(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())))
        channel.pipeline.fireChannelRead(NIOAny(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: "late"))))
        channel.embeddedEventLoop.run()

        let disconnected = await waitUntil { delegate.events.contains("disconnect:s1") }
        #expect(disconnected)
        try await Task.sleep(for: .milliseconds(50))
        #expect(delegate.events == ["connect-start:s1", "connect:s1", "disconnect:s1"])
    }

    @Test("A close the server starts (pong timeout) still disconnects the session")
    func pongTimeoutDisconnects() async throws {
        let delegate = HoldingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)

        let channel = try makeSession("s1", transport: transport)
        await waitUntil { delegate.events.contains("connect:s1") }
        // First interval: ping sent. Second interval: no pong came back, so the handler closes.
        channel.embeddedEventLoop.advanceTime(by: .seconds(30))
        channel.embeddedEventLoop.advanceTime(by: .seconds(30))
        channel.embeddedEventLoop.run()

        let disconnected = await waitUntil { delegate.events.contains("disconnect:s1") }
        #expect(disconnected, "events: \(delegate.events)")
        #expect(delegate.events.filter { $0 == "disconnect:s1" }.count == 1)
        _ = try? channel.finish()
    }
}
