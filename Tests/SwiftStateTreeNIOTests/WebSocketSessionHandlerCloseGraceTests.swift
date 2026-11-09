// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerCloseGraceTests.swift
//
// The close grace (#339): after a server close frame with a grace is written, the channel stays
// open for up to the grace. Meanwhile it is read, past an inbound pause (#113), and everything
// read is discarded, until the client's close frame closes the channel or the grace runs out.
// Time is the embedded event loop's, advanced by hand. The inbound pause is held by a delegate
// that keeps its first message until the test releases it, never by timing.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
import SwiftStateTree
import Testing
@testable import SwiftStateTreeNIO
@testable import SwiftStateTreeTransport

/// Records the messages delivered; while holding, the first one waits until `releaseAll`.
private final class GraceDelegate: TransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var holding: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(holding: Bool) { self.holding = holding }

    var messages: [String] { lock.withLock { log } }

    func releaseAll() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = false
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {}

    func onMessage(_ message: Data, from sessionID: SessionID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if holding {
                waiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
        lock.withLock { log.append(String(decoding: message, as: UTF8.self)) }
    }
}

/// Counts the `read()`s that get past the session handler (it sits in front of it).
private final class ReadCounter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = WebSocketFrame
    private(set) var count = 0
    func read(context: ChannelHandlerContext) {
        count += 1
        context.read()
    }
}

/// Holds flushes while `holding`, so a write stays incomplete until it is released. With
/// `failCloseFrames`, a close frame's write fails instead of going out.
private final class FlushHold: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = WebSocketFrame
    var holding = false
    var failCloseFrames = false
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if failCloseFrames, unwrapOutboundIn(data).opcode == .connectionClose {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        context.write(data, promise: promise)
    }
    func flush(context: ChannelHandlerContext) {
        if !holding { context.flush() }
    }
}

private struct GraceFixture {
    /// Its first keepalive ping is later than any time these tests advance (checked in `init`).
    static let sessionID = SessionID("s1")
    static let longestAdvance: TimeAmount = .seconds(3)
    /// A session whose first ping comes early, for the pong-deadline test.
    static let earlyPingSessionID: SessionID = {
        (0..<10_000).lazy.map { SessionID("p\($0)") }
            .first { WebSocketSessionHandler.initialPingDelay(for: $0) < .seconds(1) }!
    }()

    let channel: EmbeddedChannel
    let handler: WebSocketSessionHandler
    let reads: ReadCounter
    let hold: FlushHold
    let delegate: GraceDelegate

    init(
        inboundBound: InboundBacklogBound = .disabled,
        holdMessages: Bool = false,
        sendBacklogBound: SendBacklogBound = .disabled,
        sessionID: SessionID = GraceFixture.sessionID
    ) async throws {
        if sessionID == Self.sessionID {
            try #require(
                WebSocketSessionHandler.initialPingDelay(for: Self.sessionID) > Self.longestAdvance,
                "the fixture's session must not ping within the tests' time"
            )
        }
        channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        let transport = WebSocketTransport()
        delegate = GraceDelegate(holding: holdMessages)
        await transport.setDelegate(delegate)
        reads = ReadCounter()
        hold = FlushHold()
        handler = WebSocketSessionHandler(
            sessionID: sessionID,
            path: "/test",
            transport: transport,
            eventLoop: channel.eventLoop,
            sendBacklogBound: sendBacklogBound,
            inboundBacklogBound: inboundBound,
            lifecycleLog: nil,
            logger: Logger(label: "test")
        )
        // Outbound order: handler → hold → read counter → channel.
        try channel.pipeline.syncOperations.addHandler(reads)
        try channel.pipeline.syncOperations.addHandler(hold)
        try channel.pipeline.syncOperations.addHandler(handler)
    }

    func clientSends(_ text: String) throws {
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)))
    }

    func clientCloses() throws {
        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: .normalClosure)
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))
    }

    /// The frames written so far, in order.
    func writtenFrames() throws -> [WebSocketFrame] {
        var frames: [WebSocketFrame] = []
        while let frame = try channel.readOutbound(as: WebSocketFrame.self) { frames.append(frame) }
        return frames
    }

    func advance(_ amount: TimeAmount) {
        channel.embeddedEventLoop.advanceTime(by: amount)
    }
}

private func closeCode(_ frame: WebSocketFrame) -> UInt16? {
    guard frame.opcode == .connectionClose else { return nil }
    var data = frame.unmaskedData
    return data.readInteger(as: UInt16.self)
}

@Suite("WebSocketSessionHandler close grace (#339)")
struct WebSocketSessionHandlerCloseGraceTests {
    static let unresponsive = WebSocketErrorCode(codeNumber: Int(SessionClose.Code.unresponsive))

    @Test("In the grace the channel stays open and discards what the client sends; its close frame closes the channel")
    func clientCloseEndsGrace() async throws {
        let f = try await GraceFixture()
        f.handler.close(code: Self.unresponsive, reason: "unresponsive", grace: .seconds(2))
        #expect(try f.writtenFrames().map(closeCode) == [SessionClose.Code.unresponsive])
        #expect(f.channel.isActive, "the frame is written; the grace keeps the channel open")
        #expect(f.handler.isInCloseGrace)
        let deadline = try #require(f.handler.closeGraceDeadlineForTesting)

        try f.clientSends("late ack 1")
        try f.clientSends("late ack 2")
        try f.channel.writeInbound(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()))
        #expect(f.handler.closeGraceDiscardedFramesForTesting == 2)
        #expect(try f.writtenFrames().isEmpty, "no pong in the grace")
        #expect(f.channel.isActive)

        try f.clientCloses()
        #expect(!f.channel.isActive, "the client's close frame ends the grace")
        #expect(try cancelled(deadline))
        #expect(f.handler.channelCloseCallsForTesting == 1)
        await f.handler.waitForInboundIdle()
        #expect(f.delegate.messages.isEmpty, "nothing read in the grace reaches the transport")
        _ = try? f.channel.finish()
    }

    @Test("Without the client's close frame the channel closes when the grace runs out")
    func graceRunsOut() async throws {
        let f = try await GraceFixture()
        f.handler.close(code: Self.unresponsive, grace: .seconds(2))
        f.advance(.milliseconds(1999))
        #expect(f.channel.isActive)
        try f.clientSends("still sending")
        f.advance(.milliseconds(1))
        #expect(!f.channel.isActive)
        #expect(f.handler.closeGraceDeadlineForTesting == nil)
        f.advance(.seconds(1))
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("No grace, or a zero one: the channel closes as soon as the frame is written", arguments: [nil, TimeAmount.zero])
    func noGrace(grace: TimeAmount?) async throws {
        let f = try await GraceFixture()
        f.handler.close(code: Self.unresponsive, grace: grace)
        #expect(!f.channel.isActive)
        #expect(!f.handler.isInCloseGrace)
        #expect(f.handler.closeGraceDeadlineForTesting == nil)
        _ = try? f.channel.finish()
    }

    @Test("The client's close frame read while this side's frame waits to be written: closed when written, no grace")
    func clientCloseBeforeFrameWritten() async throws {
        let f = try await GraceFixture()
        f.hold.holding = true
        f.handler.close(code: Self.unresponsive, grace: .seconds(2))
        try f.clientCloses()
        #expect(f.channel.isActive, "this side's frame isn't written yet")
        f.hold.holding = false
        f.channel.flush()
        #expect(!f.channel.isActive, "the handshake completed with the write")
        #expect(!f.handler.isInCloseGrace)
        #expect(f.handler.closeGraceDeadlineForTesting == nil)
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("The grace reads past an inbound pause: the read withheld is forwarded, and later reads pass")
    func graceReadsPastPause() async throws {
        let f = try await GraceFixture(inboundBound: InboundBacklogBound(maxMessages: 1, maxBytes: 0), holdMessages: true)
        try f.clientSends("a")
        try f.clientSends("b")
        #expect(f.handler.isInboundReadPausedForTesting, "the second message crosses the bound")
        let before = f.reads.count
        f.channel.read()
        #expect(f.reads.count == before, "the read is withheld while paused")

        f.handler.close(code: Self.unresponsive, grace: .seconds(2))
        #expect(f.handler.isInCloseGrace)
        #expect(f.reads.count == before + 1, "the withheld read is forwarded")
        #expect(f.handler.isInboundReadPausedForTesting, "still paused: the held message isn't delivered")
        f.channel.read()
        #expect(f.reads.count == before + 2, "reads pass in the grace")
        try f.clientSends("c")
        #expect(f.handler.closeGraceDiscardedFramesForTesting == 1)
        #expect(f.handler.inboundQueuedMessagesForTesting == 2, "a discarded frame isn't queued")

        try f.clientCloses()
        #expect(!f.channel.isActive)
        f.delegate.releaseAll()
        await f.handler.waitForInboundIdle()
        _ = try? f.channel.finish()
    }

    @Test("A close frame whose write fails: the channel closes at once, no grace")
    func failedCloseFrameWrite() async throws {
        let f = try await GraceFixture()
        f.hold.failCloseFrames = true
        f.handler.close(code: Self.unresponsive, grace: .seconds(2))
        #expect(!f.channel.isActive)
        #expect(!f.handler.isInCloseGrace)
        #expect(f.handler.closeGraceDeadlineForTesting == nil)
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("The send-backlog bound closes the channel during the grace: once, and the grace's timer is cancelled")
    func backlogCloseDuringGrace() async throws {
        let f = try await GraceFixture(sendBacklogBound: SendBacklogBound(maxBytes: 0, maxUnwritable: .seconds(1)))
        f.handler.close(code: Self.unresponsive, grace: .seconds(2))
        let deadline = try #require(f.handler.closeGraceDeadlineForTesting)
        f.channel.isWritable = false
        f.channel.pipeline.fireChannelWritabilityChanged()
        f.advance(.seconds(1))
        #expect(!f.channel.isActive, "the backlog bound closed it")
        #expect(try cancelled(deadline))
        f.advance(.seconds(2))
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("An error during the grace closes the channel once; the timer then closes nothing")
    func errorDuringGrace() async throws {
        let f = try await GraceFixture()
        f.handler.close(code: Self.unresponsive, grace: .seconds(2))
        f.channel.pipeline.fireErrorCaught(ChannelError.ioOnClosedChannel)
        #expect(!f.channel.isActive)
        f.advance(.seconds(3))
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("A pong deadline that falls in the grace doesn't close the channel; the grace's end closes it once")
    func pongDeadlineDuringGrace() async throws {
        let id = GraceFixture.earlyPingSessionID
        let f = try await GraceFixture(sessionID: id)
        f.advance(WebSocketSessionHandler.initialPingDelay(for: id))
        #expect(try f.writtenFrames().map(\.opcode) == [.ping], "a ping waits for its pong")
        let grace = f.handler.pongTimeout + .seconds(5)
        f.handler.close(code: Self.unresponsive, grace: grace)
        _ = try f.writtenFrames()
        f.advance(f.handler.pongTimeout + .seconds(1))
        #expect(f.channel.isActive, "the pong deadline passed inside the grace")
        #expect(f.handler.channelCloseCallsForTesting == 0)
        #expect(try f.writtenFrames().isEmpty, "no close frame, no ping, in the grace")
        f.advance(.seconds(4))
        #expect(!f.channel.isActive)
        #expect(f.handler.channelCloseCallsForTesting == 1)
        _ = try? f.channel.finish()
    }

    @Test("Removing the handler during the grace cancels its timer: it never fires")
    func removalDuringGrace() async throws {
        let f = try await GraceFixture()
        f.handler.close(code: Self.unresponsive, grace: .seconds(2))
        let deadline = try #require(f.handler.closeGraceDeadlineForTesting)
        try f.channel.pipeline.removeHandler(f.handler).wait()
        #expect(try cancelled(deadline))
        #expect(f.handler.closeGraceDeadlineForTesting == nil)
        f.advance(.seconds(3))
        #expect(f.handler.channelCloseCallsForTesting == 0, "the removed handler's timer closed nothing")
        _ = try? f.channel.finish()
    }

    @Test("A SessionClose's closeGrace reaches the handler through the connection")
    func connectionPassesGrace() async throws {
        let f = try await GraceFixture()
        let connection = NIOWebSocketConnection(channel: f.channel, handler: f.handler)
        try await connection.close(with: SessionClose(code: SessionClose.Code.slowConsumer, closeGrace: .seconds(2)))
        f.channel.embeddedEventLoop.run()
        #expect(try f.writtenFrames().map(closeCode) == [SessionClose.Code.slowConsumer])
        #expect(f.handler.isInCloseGrace)
        #expect(f.channel.isActive)
        f.advance(.seconds(2))
        #expect(!f.channel.isActive)
        _ = try? f.channel.finish()
    }
}

/// Whether `task` was cancelled: its future failed with `.cancelled`.
private func cancelled(_ task: Scheduled<Void>) throws -> Bool {
    final class Box: @unchecked Sendable { var result: Result<Void, Error>? }
    let box = Box()
    task.futureResult.whenComplete { box.result = $0 }
    guard case .failure(let error)? = box.result else { return false }
    if case EventLoopError.cancelled = error { return true }
    return false
}
