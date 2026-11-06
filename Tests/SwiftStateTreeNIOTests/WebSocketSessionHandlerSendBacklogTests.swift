// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerSendBacklogTests.swift
//
// Send backlog measurement (#61 step 1): a session records the largest outbound-buffer sample
// after its writes (read from the channel's `bufferedWritableBytes`) and its unwritable
// episodes (count, longest), and reports both to the transport profiler's counters. Nothing is
// bounded yet. Time is the embedded event loop's, advanced by hand; the backlog is writes held
// before the flush, so they stay in the channel's outbound buffer.

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
    var holding = true
    func flush(context: ChannelHandlerContext) {
        if !holding { context.flush() }
    }
}

private struct BacklogFixture {
    let channel: EmbeddedChannel
    let handler: WebSocketSessionHandler
    let hold: FlushHold
    let counters: TransportProfilerCounters

    init() throws {
        channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        counters = TransportProfilerCounters()
        hold = FlushHold()
        handler = WebSocketSessionHandler(
            sessionID: SessionID("s1"),
            path: "/test",
            transport: WebSocketTransport(),
            eventLoop: channel.eventLoop,
            profilerCounters: counters,
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
}

@Suite("WebSocketSessionHandler send backlog (#61)")
struct WebSocketSessionHandlerSendBacklogTests {
    @Test("While unwritable, the largest outbound-buffer sample is the bytes the channel still holds")
    func bufferedBytesAreSampledFromTheChannel() throws {
        let f = try BacklogFixture()
        // Writable: writes are not sampled (the writable path only reads `isWritable`).
        f.send(bytes: 500)
        #expect(f.handler.sendBacklog.maxBufferedBytes == 0)

        // Turning unwritable samples once (504 held); each write while unwritable samples again.
        f.setWritable(false)
        #expect(f.handler.sendBacklog.maxBufferedBytes == 504)
        f.send(bytes: 1000)
        f.send(bytes: 1000)
        // Three frames held: payloads plus headers (4 bytes each for these payload sizes).
        #expect(f.handler.sendBacklog.maxBufferedBytes == 2512)

        f.hold.holding = false
        f.setWritable(true)
        f.send(bytes: 10)  // flushes everything; the channel holds nothing after it
        #expect(try f.channel.syncOptions!.getOption(.bufferedWritableBytes) == 0)
        #expect(f.handler.sendBacklog.maxBufferedBytes == 2512, "the max stays")
        #expect(f.counters.takeAndResetSendBacklog().bufferedBytesMax == 2512)
        #expect(f.counters.takeAndResetSendBacklog().bufferedBytesMax == 0, "reset per window")
        _ = try? f.channel.finish()
    }

    @Test("Unwritable episodes are counted and timed on the event loop's clock")
    func unwritableEpisodes() throws {
        let f = try BacklogFixture()
        f.setWritable(false)
        #expect(f.counters.takeAndResetSendBacklog().unwritableSessions == 1, "gauge while unwritable")
        f.channel.embeddedEventLoop.advanceTime(by: .milliseconds(250))
        f.setWritable(true)

        f.setWritable(false)
        f.setWritable(false)  // still the same episode
        f.channel.embeddedEventLoop.advanceTime(by: .milliseconds(40))
        f.setWritable(true)

        #expect(f.handler.sendBacklog.unwritableEpisodes == 2)
        #expect(f.handler.sendBacklog.longestUnwritable == .milliseconds(250))
        let window = f.counters.takeAndResetSendBacklog()
        #expect(window.unwritableEpisodes == 1, "the second episode; the first was taken above")
        #expect(window.unwritableLongestMs == 250)
        #expect(window.unwritableSessions == 0)
        _ = try? f.channel.finish()
    }

    @Test("A session removed while unwritable ends its episode, so the gauge comes back down")
    func removalEndsOpenEpisode() throws {
        let f = try BacklogFixture()
        f.setWritable(false)
        f.channel.embeddedEventLoop.advanceTime(by: .milliseconds(30))
        _ = try? f.channel.finish()
        let window = f.counters.takeAndResetSendBacklog()
        #expect(window.unwritableEpisodes == 1)
        #expect(window.unwritableLongestMs == 30)
        #expect(window.unwritableSessions == 0)
    }
}
