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

/// Holds flushes while `holding`, so the writes before it stay in the channel's buffer. On
/// close it fails the writes still waiting, as a real channel fails its pending writes (an
/// embedded one leaves them incomplete).
private final class FlushHold: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    var holding: Bool
    private var waiting: [ObjectIdentifier: EventLoopPromise<Void>] = [:]
    init(holding: Bool) { self.holding = holding }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard let promise else { return context.write(data, promise: nil) }
        let downstream = context.eventLoop.makePromise(of: Void.self)
        let key = ObjectIdentifier(downstream.futureResult)
        waiting[key] = promise
        downstream.futureResult.whenComplete { [self] result in
            waiting.removeValue(forKey: key)?.completeWith(result)
        }
        context.write(data, promise: downstream)
    }
    func flush(context: ChannelHandlerContext) {
        if !holding { context.flush() }
    }
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let failed = waiting.values
        waiting.removeAll()
        failed.forEach { $0.fail(ChannelError.ioOnClosedChannel) }
        context.close(mode: mode, promise: promise)
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

    init(bound: SendBacklogBound, holdFlushes: Bool, closeFrameTimeout: TimeAmount = WebSocketSessionHandler.defaultCloseFrameTimeout) throws {
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
            closeFrameTimeout: closeFrameTimeout,
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

/// Whether `task` was cancelled: its future failed with `.cancelled` (an embedded loop completes
/// it at the cancel).
private func cancelled(_ task: Scheduled<Void>) throws -> Bool {
    // The embedded loop runs the callback inline (same thread), so the box needs no lock.
    final class Box: @unchecked Sendable { var result: Result<Void, Error>? }
    let box = Box()
    task.futureResult.whenComplete { box.result = $0 }
    guard case .failure(let error)? = box.result else { return false }
    if case EventLoopError.cancelled = error { return true }
    return false
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

    @Test("Turning writable cancels the timer: the next episode, started at once, is timed from its own start")
    func writableCancelsTimer() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(2)), holdFlushes: false)
        f.setWritable(false)
        f.advance(.milliseconds(1500))
        let first = try #require(f.handler.unwritableDeadlineForTesting)
        f.setWritable(true)
        f.setWritable(false)  // a second episode from 1.5 s; its own deadline is 3.5 s
        #expect(try cancelled(first), "cancelled on writable")

        // Past the first episode's deadline (2 s): an uncancelled first timer would find the
        // channel unwritable again and close it here.
        f.advance(.milliseconds(600))
        #expect(f.channel.isActive, "the first episode's timer was cancelled")
        f.advance(.milliseconds(1400))  // 3.5 s
        #expect(!f.channel.isActive, "the second episode's own deadline")
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 1)
        _ = try? f.channel.finish()
    }

    @Test("Removing the handler while unwritable cancels the timer")
    func removalCancelsTimer() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(2)), holdFlushes: false)
        f.setWritable(false)
        f.advance(.seconds(1))
        let timer = try #require(f.handler.unwritableDeadlineForTesting)
        try f.channel.pipeline.removeHandler(f.handler).wait()
        #expect(try cancelled(timer), "cancelled on removal")
        f.advance(.seconds(3))
        #expect(f.channel.isActive, "no close from a removed handler's timer")
        #expect(f.handler.sendBacklogBreach == nil)
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 0)
        _ = try? f.channel.finish()
    }

    @Test("A server close whose frame waits behind the backlog doesn't disarm the bound", arguments: [false, true])
    func closeHandshakeKeepsBound(closeFirst: Bool) throws {
        // Flushes held: the close frame never reaches the channel, like a stalled client's.
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(2)), holdFlushes: true)
        if closeFirst {
            f.handler.close()
            f.setWritable(false)  // the episode opens after the close started
        } else {
            f.setWritable(false)
            f.advance(.milliseconds(500))
            f.handler.close()
        }
        #expect(f.channel.isActive, "the close waits for its frame")
        f.advance(.seconds(2))
        #expect(!f.channel.isActive, "the bound closes the channel anyway")
        #expect(f.handler.sendBacklogBreach == .unwritable(.seconds(2)))
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 1)
        _ = try? f.channel.finish()
    }

    @Test("A bound of 0 is disabled")
    func zeroDisables() throws {
        let f = try BoundFixture(bound: .disabled, holdFlushes: true)
        f.setWritable(false)
        for _ in 0..<10 { f.send(bytes: 10_000) }
        #expect(f.handler.unwritableDeadlineForTesting == nil, "no timer when the time bound is 0")
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

/// #229: a server close whose frame never gets written (a client stalled while its channel is
/// still writable, so no unwritable episode arms the backlog bound) is forced after
/// `closeFrameTimeout`, and counted.
@Suite("WebSocketSessionHandler close frame timeout (#229)")
struct WebSocketSessionHandlerCloseFrameTimeoutTests {
    @Test("A close frame not written within the timeout: the channel is closed anyway, counted once")
    func stalledCloseIsForced() throws {
        let f = try BoundFixture(bound: .disabled, holdFlushes: true, closeFrameTimeout: .seconds(2))
        f.handler.close()
        let deadline = try #require(f.handler.closeFrameDeadlineForTesting)
        f.advance(.milliseconds(1999))
        #expect(f.channel.isActive, "still waiting for the close frame")
        f.advance(.milliseconds(1))
        #expect(!f.channel.isActive, "forced after the timeout")
        #expect(f.counters.takeAndResetCloseFrameTimeouts() == 1)
        #expect(f.counters.takeAndResetCloseFrameTimeouts() == 0, "reset per window")
        #expect(!(try cancelled(deadline)), "it fired, not cancelled")
        // The held write fails when the channel closes; its completion must not close again.
        f.hold.holding = false
        f.channel.flush()
        f.advance(.seconds(1))
        #expect(f.handler.channelCloseCallsForTesting == 1, "the channel is closed once")
        _ = try? f.channel.finish()
    }

    @Test("A close frame written in time cancels the timer: nothing is counted")
    func writtenCloseCancelsTimer() throws {
        let f = try BoundFixture(bound: .disabled, holdFlushes: false, closeFrameTimeout: .seconds(2))
        f.handler.close()
        // The embedded write completes inside `close()`, so the deadline is already gone: its
        // completion cancelled and cleared it. Without the cancel it would still be pending.
        #expect(f.handler.closeFrameDeadlineForTesting == nil)
        #expect(!f.channel.isActive, "the frame was written, so the channel closed")
        f.advance(.seconds(3))
        #expect(f.handler.channelCloseCallsForTesting == 1)
        #expect(f.counters.takeAndResetCloseFrameTimeouts() == 0)
        _ = try? f.channel.finish()
    }

    @Test("A backlog-bound close while the frame waits: the timer doesn't count a second close")
    func backlogCloseFirstCountsOnce() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(1)), holdFlushes: true, closeFrameTimeout: .seconds(2))
        f.handler.close()
        let deadline = try #require(f.handler.closeFrameDeadlineForTesting)
        f.setWritable(false)
        f.advance(.seconds(1))
        #expect(!f.channel.isActive, "the backlog bound closed it first")
        #expect(try cancelled(deadline), "removal cancels the close frame timer")
        f.advance(.seconds(2))
        #expect(f.counters.takeAndResetSendBacklog().backlogCloses == 1)
        #expect(f.counters.takeAndResetCloseFrameTimeouts() == 0)
        _ = try? f.channel.finish()
    }
}

private struct InjectedChannelError: Error {}

/// Every close of the channel goes through `closeChannel`, so it is requested once: an error
/// closes the channel through it too.
@Suite("WebSocketSessionHandler closes the channel once")
struct WebSocketSessionHandlerCloseOnceTests {
    @Test("An error closes the channel through closeChannel")
    func errorClosesThroughCloseChannel() throws {
        let f = try BoundFixture(bound: .disabled, holdFlushes: false)
        f.channel.pipeline.fireErrorCaught(InjectedChannelError())
        #expect(!f.channel.isActive)
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("An error after the channel close was requested doesn't request it again")
    func errorAfterCloseDoesNotCloseAgain() throws {
        let f = try BoundFixture(bound: SendBacklogBound(maxBytes: 1000, maxUnwritable: .zero), holdFlushes: true)
        let context = try f.channel.pipeline.syncOperations.context(handler: f.handler)
        f.setWritable(false)
        f.send(bytes: 2000)  // over the bound: closed by the backlog bound
        #expect(f.handler.channelCloseCallsForTesting == 1)
        // Errors from the closing channel can still reach the handler before it is removed.
        f.handler.errorCaught(context: context, error: InjectedChannelError())
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("An error while a server close waits for its frame: the channel is closed once")
    func errorDuringPendingCloseClosesOnce() throws {
        let f = try BoundFixture(bound: .disabled, holdFlushes: true)
        f.handler.close()
        #expect(f.channel.isActive, "the close frame is held")
        f.channel.pipeline.fireErrorCaught(InjectedChannelError())
        #expect(!f.channel.isActive)
        // Closing failed the held frame's write; its completion didn't close again.
        f.advance(.seconds(6))
        #expect(f.handler.channelCloseCallsForTesting == 1)
        #expect(f.counters.takeAndResetCloseFrameTimeouts() == 0, "the close frame deadline was cancelled with the channel")
        _ = try? f.channel.finish()
    }
}
