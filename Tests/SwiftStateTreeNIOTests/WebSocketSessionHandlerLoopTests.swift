// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerLoopTests.swift
//
// `send` and `close` are called off the event loop (the transport's drain task, the router), but
// the handler's context and closed flag change on the loop (#144). They now hop to the loop and
// check there, in the same task as the write. These tests block the loop, queue the handler's
// removal, call `send`/`close` from the test task, then let the loop run: nothing may be written
// after the removal.
//
// Before the fix, `close(code:)` read `context.channel` off the loop, which NIO's debug assertion
// traps (`closeQueuedBeforeRemovalWritesNothing`, `offLoopSendsKeepOrder`). The old `send` read
// only plain properties off the loop, a data race no assertion sees, and its write through the
// removed context didn't reach the wire here, so `sendQueuedBeforeRemovalWritesNothing` passes on
// the old code too: it pins the contract. The race itself is `sendFromAnotherThreadRacesNothing`
// under TSan (`swift test --sanitize=thread`): on the old code TSan reports the read of the closed
// flag in `send` against its write in `handlerRemoved`. That test can fail only under TSan, and CI
// doesn't run TSan, so the race is guarded by manual TSan runs. A plain debug run still catches a
// send or close that skips the hop: `assertInEventLoop` in `sendOnLoop`/`closeOnLoop` traps
// (`offLoopSendsKeepOrder`).

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

// The tests remove the handler from a live pipeline, as a channel teardown does, but keep the
// handler in front of it that counts what reaches the wire.
extension WebSocketSessionHandler: RemovableChannelHandler {}

/// Counts the frames written through it (the session handler's writes pass it on their way out).
private final class FrameCounter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let lock = NSLock()
    private var frames: [WebSocketOpcode] = []
    private var entries: [String] = []

    var opcodes: [WebSocketOpcode] { lock.lock(); defer { lock.unlock() }; return frames }
    /// Each frame in write order: a binary frame as its payload text, any other by its opcode.
    var sequence: [String] { lock.lock(); defer { lock.unlock() }; return entries }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = unwrapOutboundIn(data)
        let entry = frame.opcode == .binary ? String(buffer: frame.data) : "\(frame.opcode)"
        lock.lock(); frames.append(frame.opcode); entries.append(entry); lock.unlock()
        context.write(data, promise: promise)
    }
}

private struct Fixture {
    let channel: NIOAsyncTestingChannel
    let handler: WebSocketSessionHandler
    let counter: FrameCounter
}

private func makeFixture() async throws -> Fixture {
    let counter = FrameCounter()
    let channel = await NIOAsyncTestingChannel()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID("s1"),
        path: "/test",
        transport: WebSocketTransport(),
        eventLoop: channel.eventLoop,
        logger: Logger(label: "test")
    )
    try await channel.pipeline.addHandler(counter).get()
    try await channel.pipeline.addHandler(handler).get()
    return Fixture(channel: channel, handler: handler, counter: counter)
}

/// Holds the event loop until `release`: tasks queued meanwhile run after it, in order.
private final class LoopBlocker: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    init(_ loop: EventLoop) {
        loop.execute { [semaphore] in semaphore.wait() }
    }

    func release() { semaphore.signal() }
}

/// Returns once every task queued on `loop` before this call has run.
private func drain(_ loop: EventLoop) async throws {
    try await loop.submit {}.get()
}

@Suite("WebSocketSessionHandler: loop-bound state (#144)", .timeLimit(.minutes(1)))
struct WebSocketSessionHandlerLoopTests {
    @Test("A send called off the loop before the handler's removal writes nothing once the loop runs it")
    func sendQueuedBeforeRemovalWritesNothing() async throws {
        let fixture = try await makeFixture()
        let loop = fixture.channel.eventLoop
        let blocker = LoopBlocker(loop)
        // Queued behind the blocker: the removal runs first, then whatever `send` queued.
        let removed = loop.makePromise(of: Void.self)
        fixture.channel.pipeline.removeHandler(fixture.handler, promise: removed)
        fixture.handler.send(ByteBuffer(string: "late"))
        blocker.release()
        try await removed.futureResult.get()
        try await drain(loop)
        #expect(fixture.counter.opcodes == [], "frames after removal: \(fixture.counter.opcodes)")
    }

    @Test("A close called off the loop before the handler's removal sends no close frame once the loop runs it")
    func closeQueuedBeforeRemovalWritesNothing() async throws {
        let fixture = try await makeFixture()
        let loop = fixture.channel.eventLoop
        let blocker = LoopBlocker(loop)
        let removed = loop.makePromise(of: Void.self)
        fixture.channel.pipeline.removeHandler(fixture.handler, promise: removed)
        fixture.handler.close(code: .goingAway)
        blocker.release()
        try await removed.futureResult.get()
        try await drain(loop)
        #expect(fixture.counter.opcodes == [], "frames after removal: \(fixture.counter.opcodes)")
    }

    @Test("A send called on the loop after the handler's removal writes nothing")
    func sendOnLoopAfterRemovalWritesNothing() async throws {
        let fixture = try await makeFixture()
        try await fixture.channel.pipeline.removeHandler(fixture.handler)
        let handler = fixture.handler
        try await fixture.channel.eventLoop.submit { handler.send(ByteBuffer(string: "late")) }.get()
        #expect(fixture.counter.opcodes == [])
    }

    @Test("Sends called off the loop are written in call order; a close after them comes last")
    func offLoopSendsKeepOrder() async throws {
        let fixture = try await makeFixture()
        for index in 0..<20 {
            fixture.handler.send(ByteBuffer(string: "m\(index)"))
        }
        fixture.handler.close(code: .normalClosure)
        fixture.handler.send(ByteBuffer(string: "after-close"))
        try await drain(fixture.channel.eventLoop)
        let sequence = fixture.counter.sequence
        let close = "\(WebSocketOpcode.connectionClose)"
        #expect(sequence == (0..<20).map { "m\($0)" } + [close], "frames: \(sequence)")
    }

    @Test("Sends from another thread during the handler's removal touch no loop state off the loop (run under TSan)")
    func sendFromAnotherThreadRacesNothing() async throws {
        for _ in 0..<50 {
            let fixture = try await makeFixture()
            let handler = fixture.handler
            let sent = DispatchGroup()
            sent.enter()
            let sender = Thread {
                for _ in 0..<200 { handler.send(ByteBuffer(string: "x")) }
                sent.leave()
            }
            sender.start()
            let removed = fixture.channel.eventLoop.makePromise(of: Void.self)
            fixture.channel.pipeline.removeHandler(handler, promise: removed)
            try await removed.futureResult.get()
            await withCheckedContinuation { continuation in
                sent.notify(queue: .global()) { continuation.resume() }
            }
            try await drain(fixture.channel.eventLoop)
            // Every frame that reached the wire was written before the removal.
            #expect(fixture.counter.opcodes.allSatisfy { $0 == .binary })
        }
    }
}
