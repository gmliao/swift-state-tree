// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerKeepaliveTests.swift
//
// WebSocket keepalive (#108). Each session pings at its own phase of the ping interval: its first
// ping comes at a stable offset from a hash of its session ID, so sessions that connect together
// don't ping together. A ping with no pong closes the connection after the pong timeout, not at
// the next ping; a pong cancels that deadline. Time is the embedded event loop's, advanced by hand.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

private func makeSession(_ sessionID: String) throws -> EmbeddedChannel {
    let channel = EmbeddedChannel()
    // Active, so a close shows as `isActive == false`.
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
        let ids = (0..<64).map { _ in SessionID(UUID().uuidString) }
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

    @Test("A ping without a pong closes the connection at the pong timeout, not at the next ping")
    func missingPongClosesAtTimeout() throws {
        let channel = try makeSession("silent-peer")
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID("silent-peer")))
        #expect(try written(channel) == [.ping])

        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.pongTimeout - millisecond)
        #expect(try written(channel) == [])
        #expect(channel.isActive)

        channel.embeddedEventLoop.advanceTime(by: millisecond)
        #expect(try written(channel) == [.connectionClose])
        #expect(!channel.isActive, "closed after the close frame")
    }

    @Test("A pong cancels the timeout; the connection stays open and pings on schedule")
    func pongCancelsTheTimeout() throws {
        let channel = try makeSession("live-peer")
        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.initialPingDelay(for: SessionID("live-peer")))
        #expect(try written(channel) == [.ping])
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer()))

        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.pongTimeout + .seconds(1))
        #expect(try written(channel) == [])
        #expect(channel.isActive)

        channel.embeddedEventLoop.advanceTime(by: WebSocketSessionHandler.pingInterval - WebSocketSessionHandler.pongTimeout - .seconds(1))
        #expect(try written(channel) == [.ping], "the next ping, one interval after the first")
        _ = try? channel.finish()
    }
}
