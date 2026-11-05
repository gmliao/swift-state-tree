// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerKeepaliveTests.swift
//
// WebSocket keepalive (#108). Each session pings at its own phase of the ping interval: its first
// ping comes at a stable offset from a hash of its session ID, so sessions that connect together
// don't ping together. A ping followed by no inbound frame closes the connection after the pong
// timeout, not at the next ping; any frame from the peer (a pong, or a text or binary message)
// cancels that deadline. The timeout is configurable (default 20 s) and each close is counted in
// the transport profiler's counters. Time is the embedded event loop's, advanced by hand.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

private func makeSession(
    _ sessionID: String,
    pongTimeout: TimeAmount = WebSocketSessionHandler.defaultPongTimeout,
    profilerCounters: TransportProfilerCounters? = nil
) throws -> EmbeddedChannel {
    let channel = EmbeddedChannel()
    // Active, so a close shows as `isActive == false`.
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(sessionID),
        path: "/test",
        transport: WebSocketTransport(),
        eventLoop: channel.eventLoop,
        pongTimeout: pongTimeout,
        profilerCounters: profilerCounters,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(handler)
    return channel
}

/// The opcodes of the frames the channel wrote since the last call.
private func written(_ channel: EmbeddedChannel) throws -> [WebSocketOpcode] {
    var opcodes: [WebSocketOpcode] = []
    while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
        opcodes.append(frame.opcode)
    }
    return opcodes
}

private let millisecond = TimeAmount.milliseconds(1)

@Suite("WebSocketSessionHandler keepalive (#108)")
struct WebSocketSessionHandlerKeepaliveTests {
    @Test("First-ping delays are stable per session and spread over the interval")
    func initialDelaysSpread() {
        let interval = WebSocketSessionHandler.pingInterval
        // Fixed IDs, shaped like the server's (UUID strings), so the test is the same every run.
        let ids = (0..<64).map { SessionID("00000000-0000-4000-8000-" + String(1_000_000_000_000 + $0).dropFirst()) }
        let delays = ids.map { WebSocketSessionHandler.initialPingDelay(for: $0) }
        for (id, delay) in zip(ids, delays) {
            #expect(delay > .zero && delay < interval, "\(id.rawValue): \(delay)")
            #expect(WebSocketSessionHandler.initialPingDelay(for: id) == delay, "stable per session")
        }
        // 64 sessions over 30 s: almost all distinct, and spread over most of the interval.
        #expect(Set(delays.map(\.nanoseconds)).count >= 60)
        let span = delays.max()!.nanoseconds - delays.min()!.nanoseconds
        #expect(span > interval.nanoseconds / 2, "span \(span) ns")
    }

    @Test("Sessions added at the same instant ping first at their own offsets, not together")
    func firstPingsAtOwnOffsets() throws {
        let ids = ["session-a", "session-b", "session-c"]
        let delays = ids.map { WebSocketSessionHandler.initialPingDelay(for: SessionID($0)) }
        #expect(Set(delays.map(\.nanoseconds)).count == ids.count)

        for (id, delay) in zip(ids, delays) {
            let channel = try makeSession(id)
            channel.embeddedEventLoop.advanceTime(by: delay - millisecond)
            #expect(try written(channel) == [], "\(id): no ping before its offset")
            channel.embeddedEventLoop.advanceTime(by: millisecond)
            #expect(try written(channel) == [.ping], "\(id): its first ping at its offset")
            // Then every interval, keeping the phase.
            try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer()))
            channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.pingInterval - millisecond)
            #expect(try written(channel) == [])
            channel.embeddedEventLoop.advanceTime(by: millisecond)
            #expect(try written(channel) == [.ping])
            _ = try? channel.finish()
        }
    }

    @Test("A ping with no inbound frame closes the connection at the pong timeout (20 s), not at the next ping")
    func missingPongClosesAtTimeout() throws {
        #expect(WebSocketSessionHandler.defaultPongTimeout == .seconds(20))
        let channel = try makeSession("silent-peer")
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID("silent-peer")))
        #expect(try written(channel) == [.ping])

        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.defaultPongTimeout - millisecond)
        #expect(try written(channel) == [])
        #expect(channel.isActive)

        channel.embeddedEventLoop.advanceTime(by: millisecond)
        #expect(try written(channel) == [.connectionClose])
        #expect(!channel.isActive, "closed after the close frame")
    }

    @Test("Any inbound frame answers an outstanding ping: a text or binary frame before the deadline keeps it open", arguments: [WebSocketOpcode.text, .binary])
    func inboundFrameCountsAsLiveness(opcode: WebSocketOpcode) throws {
        let channel = try makeSession("busy-peer")
        let timeout = WebSocketSessionHandler.defaultPongTimeout
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID("busy-peer")))
        #expect(try written(channel) == [.ping])

        // No pong, but a message from the peer just before the deadline.
        channel.embeddedEventLoop.advanceTime(by: timeout - millisecond)
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: opcode, data: ByteBuffer(string: "x")))
        // Past the deadline (+1 ms) and up to the next ping, one interval after the first.
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.pingInterval - timeout + millisecond)
        #expect(try written(channel) == [.ping], "still open: the next ping, one interval after the first")
        #expect(channel.isActive)

        // That ping goes unanswered and nothing else comes in: closed at its deadline.
        channel.embeddedEventLoop.advanceTime(by: timeout - millisecond)
        #expect(channel.isActive)
        channel.embeddedEventLoop.advanceTime(by: millisecond)
        #expect(try written(channel) == [.connectionClose])
        #expect(!channel.isActive)
    }

    @Test("A configured pong timeout is the one enforced, and the close is counted")
    func configuredTimeoutIsEnforcedAndCounted() throws {
        let counters = TransportProfilerCounters()
        let timeout = TimeAmount.seconds(25)
        let channel = try makeSession("slow-peer", pongTimeout: timeout, profilerCounters: counters)
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID("slow-peer")))
        #expect(try written(channel) == [.ping])

        // Past the default timeout: still open.
        channel.embeddedEventLoop.advanceTime(by: timeout - millisecond)
        #expect(try written(channel) == [])
        #expect(channel.isActive)
        #expect(counters.takeAndResetPongTimeoutCloses() == 0)

        channel.embeddedEventLoop.advanceTime(by: millisecond)
        #expect(try written(channel) == [.connectionClose])
        #expect(!channel.isActive)
        #expect(counters.takeAndResetPongTimeoutCloses() == 1)
    }

    @Test("A pong cancels the timeout; the connection stays open and pings on schedule")
    func pongCancelsTheTimeout() throws {
        let channel = try makeSession("live-peer")
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID("live-peer")))
        #expect(try written(channel) == [.ping])
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer()))

        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.defaultPongTimeout + .seconds(1))
        #expect(try written(channel) == [])
        #expect(channel.isActive)

        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.pingInterval - WebSocketSessionHandler.defaultPongTimeout - .seconds(1))
        #expect(try written(channel) == [.ping], "the next ping, one interval after the first")
        _ = try? channel.finish()
    }
}
