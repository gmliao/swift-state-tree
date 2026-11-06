// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerSendBacklogBoundTests.swift
//
// Send backlog bound (#61 step 3, option A): a session whose channel holds more than
// `maxBytes` while unwritable, or stays unwritable longer than `maxUnwritable`, is closed with
// 4008 and counted. 0 disables a bound. The timer starts with the unwritable episode and is
// cancelled when the channel turns writable or the handler is removed. Time is the embedded
// event loop's, advanced by hand; the byte backlog is writes held before the flush.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

/// Holds flushes while `holding`, so the writes before it stay in the channel's buffer.
private final class FlushHold: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    var holding: Bool
    init(holding: Bool) { self.holding = holding }
    func flush(context: ChannelHandlerContext) {
        if !holding { context.flush() }
    }
}

private struct BoundFixture {
    /// Its first keepalive ping is later than any time these tests advance, so a pong timeout
    /// never closes the channel first (checked in `init`).
    static let sessionID = SessionID("s1")
    static let longestAdvance: TimeAmount = .seconds(5)

    let channel: EmbeddedChannel
    let handler: WebSocketSessionHandler
    let hold: FlushHold
    let counters: TransportProfilerCounters

    init(bound: SendBacklogBound, holdFlushes: Bool) throws {
        try #require(
            WebSocketSessionHandler.initialPingDelay(for: Self.sessionID) > Self.longestAdvance,
            "the fixture's session must not ping within the tests' time"
        )
        channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        counters = TransportProfilerCounters()
        hold = FlushHold(holding: holdFlushes)
        handler = WebSocketSessionHandler(
            sessionID: Self.sessionID,
            path: "/test",
            transport: WebSocketTransport(),
            eventLoop: channel.eventLoop,
            profilerCounters: counters,
            sendBacklogBound: bound,
            logger: Logger(label: "test")
        )
        // Outbound order: handler → hold → encoder → channel, so the channel buffers bytes.
        try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
        try channel.pipeline.syncOperations.addHandler(hold)
        try channel.pipeline.syncOperations.addHandler(handler)
    }

    func send(bytes: Int) {
        var buffer = channel.allocator.buffer(capacity: bytes)
        buffer.writeRepeatingByte(7, count: bytes)
        handler.send(buffer)
    }

    func setWritable(_ writable: Bool) {
        channel.isWritable = writable
        channel.pipeline.fireChannelWritabilityChanged()
    }

    func advance(_ amount: TimeAmount) {
        channel.embeddedEventLoop.advanceTime(by: amount)
    }

    /// Every byte the channel has written, in order.
    func writtenBytes() throws -> [UInt8] {
        var bytes: [UInt8] = []
        while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
            bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
        }
        return bytes
    }
}

@Suite("WebSocketSessionHandler send backlog bound (#61)")
struct WebSocketSessionHandlerSendBacklogBoundTests {
    @Test("Above maxBytes while unwritable, the session is closed and counted; at or below it, not")
    func bytesBound() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 2000, maxUnwritable: .zero), holdFlushes: true)
        f.send(bytes: 500)
        f.setWritable(false)  // samples 504 held bytes
        f.send(bytes: 1000)  // 1508
        #expect(f.channel.isActive, "1508 bytes held, under the bound")
        #expect(f.handler.sendBacklogBreach == nil)

        f.send(bytes: 1000)  // 2512 > 2000
        #expect(!f.channel.isActive, "closed over the bound")
        #expect(f.handler.sendBacklogBreach == .bytes(2512))
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 1)
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 0, "reset per window")
        _ = try? f.channel.finish()
    }

    @Test("Unwritable longer than maxUnwritable: closed with a 4008 close frame, counted")
    func timeBound() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(2)), holdFlushes: false)
        f.setWritable(false)
        f.advance(.milliseconds(1999))
        #expect(f.channel.isActive, "just under the bound")
        f.advance(.milliseconds(1))
        #expect(!f.channel.isActive)
        #expect(f.handler.sendBacklogBreach == .unwritable(.seconds(2)))
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 1)
        // The close frame: FIN + close opcode, length 2, status 4008 (0x0FA8).
        #expect(try f.writtenBytes().suffix(4) == [0x88, 0x02, 0x0F, 0xA8])
        _ = try? f.channel.finish()
    }

    @Test("Turning writable cancels the timer; the next episode starts its own")
    func writableCancelsTimer() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(2)), holdFlushes: false)
        f.setWritable(false)
        f.advance(.milliseconds(1500))
        #expect(f.handler.hasUnwritableDeadlineForTesting)
        f.setWritable(true)
        #expect(!f.handler.hasUnwritableDeadlineForTesting, "cancelled on writable")
        f.advance(.seconds(1))
        #expect(f.channel.isActive, "the first episode's timer was cancelled")

        f.setWritable(false)
        f.advance(.milliseconds(1500))
        #expect(f.channel.isActive, "the second episode is timed from its own start")
        f.advance(.milliseconds(500))
        #expect(!f.channel.isActive)
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 1)
        _ = try? f.channel.finish()
    }

    @Test("Removing the handler while unwritable cancels the timer")
    func removalCancelsTimer() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(2)), holdFlushes: false)
        f.setWritable(false)
        f.advance(.seconds(1))
        #expect(f.handler.hasUnwritableDeadlineForTesting)
        try f.channel.pipeline.removeHandler(f.handler).wait()
        #expect(!f.handler.hasUnwritableDeadlineForTesting, "cancelled on removal")
        f.advance(.seconds(3))
        #expect(f.channel.isActive, "no close from a removed handler's timer")
        #expect(f.handler.sendBacklogBreach == nil)
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 0)
        _ = try? f.channel.finish()
    }

    @Test("A bound of 0 is disabled")
    func zeroDisables() throws {
        let f = try BoundFixture(bound: .disabled, holdFlushes: true)
        f.setWritable(false)
        for _ in 0..<10 { f.send(bytes: 10_000) }
        #expect(!f.handler.hasUnwritableDeadlineForTesting, "no timer when the time bound is 0")
        f.advance(.seconds(5))
        #expect(f.channel.isActive)
        #expect(f.handler.sendBacklogBreach == nil)
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 0)
        _ = try? f.channel.finish()
    }
}

@Suite("Send backlog bound configuration (#61)")
struct SendBacklogBoundConfigurationTests {
    @Test("Defaults: 8 MiB and 30 s")
    func defaults() {
        let bound = NIOWebSocketServerConfiguration.sendBacklogBound(environment: [:])
        #expect(bound == SendBacklogBound.default)
        #expect(bound.maxBytes == 8 << 20)
        #expect(bound.maxUnwritable == .seconds(30))
    }

    @Test("The env keys set each bound; 0 disables it")
    func environment() {
        let bound = NIOWebSocketServerConfiguration.sendBacklogBound(environment: [
            "WS_SEND_BACKLOG_MAX_BYTES": "1048576",
            "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": "0",
        ])
        #expect(bound == SendBacklogBound(maxBytes: 1 << 20, maxUnwritable: .zero))
    }

    @Test("A value that is set but invalid gives that bound's default", arguments: ["-1", "abc", ""])
    func invalidValues(raw: String) {
        let bound = NIOWebSocketServerConfiguration.sendBacklogBound(environment: [
            "WS_SEND_BACKLOG_MAX_BYTES": raw,
            "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": raw,
        ])
        #expect(bound == SendBacklogBound.default)
        #expect(NIOWebSocketServerConfiguration.rejectedSendBacklogKeys(environment: [
            "WS_SEND_BACKLOG_MAX_BYTES": raw,
        ]) == ["WS_SEND_BACKLOG_MAX_BYTES"])
    }

    @Test("The host configuration passes its bound to the WebSocket server")
    func hostPassesBound() {
        let bound = SendBacklogBound(maxBytes: 123, maxUnwritable: .seconds(4))
        let host = NIOLandHostConfiguration(sendBacklogBound: bound)
        #expect(host.webSocketServerConfiguration().sendBacklogBound == bound)
    }
}
