// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerInboundBacklogTests.swift
//
// A session whose messages are read faster than the transport takes them stops being read at its
// inbound backlog bound, and is read again once half the backlog is delivered (#113). The
// delegate holds each message until the test releases it, never timing. A counting handler at
// the head of the pipeline sees the `read()`s the session handler lets through; `pump` writes one
// frame per read that gets there, as `autoRead` would.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
import SwiftStateTree
import Testing
@testable import SwiftStateTreeNIO
@testable import SwiftStateTreeTransport

/// Records delegate calls. While holding, each message waits in `onMessage` until `releaseNext`
/// (the chain delivers one at a time, so at most one waits).
private final class BacklogDelegate: TransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var holding = true
    private var waiter: CheckedContinuation<Void, Never>?

    var events: [String] { lock.withLock { log } }
    var isMessageWaiting: Bool { lock.withLock { waiter != nil } }

    /// Lets the waiting message (if any) through.
    func releaseNext() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { waiter = nil }
            return waiter
        }
        next?.resume()
    }

    /// Holds again, from the next message on.
    func hold() {
        lock.withLock { holding = true }
    }

    /// Stops holding: the waiting message and every later one go through.
    func releaseAll() {
        lock.withLock { holding = false }
        releaseNext()
    }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {
        lock.withLock { log.append("connect") }
    }

    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        lock.withLock { log.append("disconnect") }
    }

    func onMessage(_ message: Data, from sessionID: SessionID) async {
        let text = String(decoding: message, as: UTF8.self)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if holding {
                waiter = continuation
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
        lock.withLock { log.append(text) }
    }
}

/// Counts the `read()`s that get past the session handler (it sits in front of it).
private final class ReadCounter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = WebSocketFrame

    private let lock = NSLock()
    private var reads = 0

    var count: Int { lock.withLock { reads } }

    func read(context: ChannelHandlerContext) {
        lock.withLock { reads += 1 }
        context.read()
    }
}

private struct Fixture {
    let channel: NIOAsyncTestingChannel
    let handler: WebSocketSessionHandler
    let reads: ReadCounter
    let delegate: BacklogDelegate

    var loop: EventLoop { channel.eventLoop }
}

private func makeFixture(
    bound: InboundBacklogBound,
    transport: WebSocketTransport = WebSocketTransport(),
    sessionID: String = "s1",
    delegate: BacklogDelegate = BacklogDelegate()
) async throws -> Fixture {
    await transport.setDelegate(delegate)
    let reads = ReadCounter()
    let channel = await NIOAsyncTestingChannel()
    let handler = WebSocketSessionHandler(
        sessionID: SessionID(sessionID),
        path: "/test",
        transport: transport,
        eventLoop: channel.eventLoop,
        inboundBacklogBound: bound,
        logger: Logger(label: "test")
    )
    try await channel.pipeline.addHandler(reads).get()
    try await channel.pipeline.addHandler(handler).get()
    let fixture = Fixture(channel: channel, handler: handler, reads: reads, delegate: delegate)
    try await drain(fixture.loop)
    return fixture
}

/// Returns once every task queued on `loop` before this call has run.
private func drain(_ loop: EventLoop) async throws {
    try await loop.submit {}.get()
}

private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await safeTaskSleep(for: .milliseconds(2))
    }
    return condition()
}

private func onLoop<T: Sendable>(_ fixture: Fixture, _ body: @escaping @Sendable () -> T) async throws -> T {
    try await fixture.loop.submit(body).get()
}

/// Asks for one read; when it reaches the head of the pipeline, delivers `text` as one frame and
/// flushes it as its own batch. Returns whether the read got through.
@discardableResult
private func readOne(_ fixture: Fixture, _ text: String) async throws -> Bool {
    let before = fixture.reads.count
    try await onLoop(fixture) { fixture.channel.pipeline.read() }
    guard fixture.reads.count > before else { return false }
    try await fixture.channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)))
    try await drain(fixture.loop)
    return true
}

/// `readOne` for each of `texts`, until a read is withheld. Returns the texts delivered.
private func pump(_ fixture: Fixture, _ texts: [String]) async throws -> [String] {
    var delivered: [String] = []
    for text in texts {
        guard try await readOne(fixture, text) else { break }
        delivered.append(text)
    }
    return delivered
}

private func messages(_ count: Int, size: Int = 1) -> [String] {
    (0..<count).map { i in
        let tag = "m\(i)"
        return tag + String(repeating: "x", count: max(0, size - tag.utf8.count))
    }
}

@Suite("WebSocketSessionHandler: inbound backlog bound (#113)", .timeLimit(.minutes(1)))
struct WebSocketSessionHandlerInboundBacklogTests {
    @Test("A held message and a flood: reads stop at the message bound, after one message over it")
    func messageBoundStopsReads() async throws {
        let f = try await makeFixture(bound: InboundBacklogBound(maxMessages: 8, maxBytes: 0))
        let delivered = try await pump(f, messages(50))
        #expect(delivered.count == 9, "the 9th message crosses the bound; the next read is withheld")
        #expect(f.handler.isInboundReadPausedForTesting)
        #expect(f.handler.inboundQueuedMessagesForTesting == 9)
        let stats = try await onLoop(f) { f.handler.inboundBacklog }
        #expect(stats.readPauses == 1)
        #expect(stats.maxQueuedMessages == 9)
        // Further reads asked for while paused are withheld too.
        #expect(try await !readOne(f, "late"))
        f.delegate.releaseAll()
    }

    @Test("The byte bound: exceeded by at most one maximum message")
    func byteBoundSlack() async throws {
        let frameSize = 100
        let f = try await makeFixture(bound: InboundBacklogBound(maxMessages: 0, maxBytes: 1_000))
        let delivered = try await pump(f, messages(50, size: frameSize))
        #expect(f.handler.isInboundReadPausedForTesting)
        let stats = try await onLoop(f) { f.handler.inboundBacklog }
        #expect(stats.maxQueuedBytes > 1_000, "the bound was crossed")
        #expect(stats.maxQueuedBytes <= 1_000 + frameSize, "bound + one maximum message")
        #expect(delivered.count == 11)
        f.delegate.releaseAll()
    }

    @Test("Reads resume at the low watermark, half the bound, and not before")
    func resumeAtLowWatermark() async throws {
        let f = try await makeFixture(bound: InboundBacklogBound(maxMessages: 8, maxBytes: 0))
        let delivered = try await pump(f, messages(20))
        #expect(delivered.count == 9)
        // A withheld read, pending.
        let readsBefore = f.reads.count
        #expect(try await !readOne(f, "pending"))

        // Release one message at a time: 9 queued, the bound's half is 4.
        for remaining in stride(from: 8, through: 5, by: -1) {
            #expect(await waitUntil { f.delegate.isMessageWaiting })
            f.delegate.releaseNext()
            #expect(await waitUntil { f.handler.inboundQueuedMessagesForTesting == remaining })
            try await drain(f.loop)
            #expect(f.handler.isInboundReadPausedForTesting, "still above half at \(remaining)")
            #expect(f.reads.count == readsBefore, "no read forwarded at \(remaining)")
        }
        #expect(await waitUntil { f.delegate.isMessageWaiting })
        f.delegate.releaseNext()
        #expect(await waitUntil { f.handler.inboundQueuedMessagesForTesting == 4 })
        #expect(await waitUntil { !f.handler.isInboundReadPausedForTesting })
        try await drain(f.loop)
        #expect(f.reads.count == readsBefore + 1, "the withheld read is forwarded once")
        let stats = try await onLoop(f) { f.handler.inboundBacklog }
        #expect(stats.readPauses == 1)
        f.delegate.releaseAll()
    }

    @Test("Order is kept across a pause; the disconnect comes after every message")
    func orderAcrossPause() async throws {
        let f = try await makeFixture(bound: InboundBacklogBound(maxMessages: 4, maxBytes: 0))
        let texts = messages(30)
        var delivered = try await pump(f, texts)
        #expect(f.handler.isInboundReadPausedForTesting)
        // Release everything; keep reading as reads are let through again.
        f.delegate.releaseAll()
        while delivered.count < texts.count {
            // Reads must come back; a pause that never ends fails here instead of spinning.
            guard await waitUntil({ !f.handler.isInboundReadPausedForTesting }) else {
                Issue.record("reads never resumed, at \(delivered.count) of \(texts.count)")
                break
            }
            delivered += try await pump(f, Array(texts[delivered.count...]))
        }
        try await f.channel.close()
        #expect(await waitUntil { f.delegate.events.last == "disconnect" })
        #expect(f.delegate.events == ["connect"] + texts + ["disconnect"])
        let stats = try await onLoop(f) { f.handler.inboundBacklog }
        #expect(stats.readPauses >= 1)
    }

    @Test("A server-side close while paused: the queued messages, then the disconnect")
    func serverCloseWhilePaused() async throws {
        let f = try await makeFixture(bound: InboundBacklogBound(maxMessages: 4, maxBytes: 0))
        let delivered = try await pump(f, messages(20))
        #expect(f.handler.isInboundReadPausedForTesting)
        // The handler is removed (a server close): the pause ends, the disconnect is queued.
        try await f.channel.close()
        #expect(!f.handler.isInboundReadPausedForTesting)
        f.delegate.releaseAll()
        #expect(await waitUntil { f.delegate.events.last == "disconnect" })
        #expect(f.delegate.events == ["connect"] + delivered + ["disconnect"])
    }

    @Test("A rejected connection's dropped batches leave the backlog")
    func rejectedConnectionDrains() async throws {
        let transport = WebSocketTransport()
        let delegate = BacklogDelegate()
        delegate.releaseAll()
        await transport.setDelegate(delegate)
        // The first connection holds the SessionID, so the second is rejected.
        let holder = try await makeFixture(bound: .default, transport: transport, sessionID: "dup", delegate: delegate)
        #expect(await waitUntil { delegate.events == ["connect"] })

        // The second handler is added and read in one loop task: its frames are counted before
        // the transport's rejection (on the chain, after this task) can close the channel.
        let channel = await NIOAsyncTestingChannel()
        let handler = WebSocketSessionHandler(
            sessionID: SessionID("dup"),
            path: "/test",
            transport: transport,
            eventLoop: channel.eventLoop,
            inboundBacklogBound: InboundBacklogBound(maxMessages: 2, maxBytes: 0),
            logger: Logger(label: "test")
        )
        let (counted, paused) = try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(handler)
            for text in messages(5) {
                channel.pipeline.fireChannelRead(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)))
            }
            // Read in this loop task: once it ends, the rejection may drop the batches and resume.
            return (handler.inboundQueuedMessagesForTesting, handler.isInboundReadPausedForTesting)
        }.get()
        #expect(counted == 5, "counted before the rejection")
        #expect(paused, "and over the bound")
        #expect(await waitUntil { handler.inboundQueuedMessagesForTesting == 0 }, "dropped batches subtracted")
        #expect(delegate.events == ["connect"], "the rejected connection's frames are dropped")
        _ = holder
    }

    @Test("A close while paused: the profiler's paused gauge comes back to 0, the stats record the pause")
    func pauseGaugeAtRemoval() async throws {
        let counters = TransportProfilerCounters()
        let delegate = BacklogDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)
        let reads = ReadCounter()
        let channel = await NIOAsyncTestingChannel()
        let handler = WebSocketSessionHandler(
            sessionID: SessionID("s-gauge"),
            path: "/test",
            transport: transport,
            eventLoop: channel.eventLoop,
            profilerCounters: counters,
            inboundBacklogBound: InboundBacklogBound(maxMessages: 2, maxBytes: 0),
            logger: Logger(label: "test")
        )
        try await channel.pipeline.addHandler(reads).get()
        try await channel.pipeline.addHandler(handler).get()
        let f = Fixture(channel: channel, handler: handler, reads: reads, delegate: delegate)
        _ = try await pump(f, messages(10))
        #expect(handler.isInboundReadPausedForTesting)
        let paused = counters.takeAndResetInboundBacklog()
        #expect(paused.pausedSessions == 1)
        #expect(paused.readPauses == 1)
        #expect(paused.queuedMessagesMax == 3)

        try await channel.close()
        let window = counters.takeAndResetInboundBacklog()
        #expect(window.pausedSessions == 0, "the removal ends the pause")
        delegate.releaseAll()
        #expect(await waitUntil { delegate.events.last == "disconnect" })
    }

    @Test("A resume queued behind the handler's removal forwards no read")
    func resumeAfterRemoval() async throws {
        let f = try await makeFixture(bound: InboundBacklogBound(maxMessages: 2, maxBytes: 0))
        _ = try await pump(f, messages(10))
        #expect(f.handler.isInboundReadPausedForTesting)
        #expect(try await !readOne(f, "pending"), "a read is withheld, pending")
        let readsBefore = f.reads.count

        // Hold the loop; queue the removal, then let the backlog drain: its resume queues after
        // the removal.
        let gate = DispatchSemaphore(value: 0)
        f.loop.execute { gate.wait() }
        let removed = f.loop.makePromise(of: Void.self)
        f.channel.pipeline.removeHandler(f.handler, promise: removed)
        f.delegate.releaseAll()
        #expect(await waitUntil { f.handler.inboundQueuedMessagesForTesting == 0 })
        gate.signal()
        try await removed.futureResult.get()
        try await drain(f.loop)
        #expect(f.reads.count == readsBefore, "no read after the removal")
        #expect(!f.handler.isInboundReadPausedForTesting)
    }

    @Test("A resume queued by a drain, behind frames that refill past the bound, forwards no read")
    func resumeRechecksTheCounts() async throws {
        let f = try await makeFixture(bound: InboundBacklogBound(maxMessages: 4, maxBytes: 0))
        _ = try await pump(f, messages(10))
        #expect(f.handler.isInboundReadPausedForTesting)
        #expect(try await !readOne(f, "pending"), "a read is withheld, pending")
        let readsBefore = f.reads.count

        // The loop: blocked, then a task that refills past the bound (frames already decoded from
        // the same read cycle), then the drain's resume hop.
        let blocker = DispatchSemaphore(value: 0)
        let refillGate = DispatchSemaphore(value: 0)
        f.loop.execute { blocker.wait() }
        let channel = f.channel
        f.loop.execute {
            refillGate.wait()
            for text in messages(6, size: 2) {
                channel.pipeline.fireChannelRead(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)))
            }
        }
        f.delegate.releaseAll()
        // Drained under the lock while paused: the resume hop is queued behind the refill.
        #expect(await waitUntil { f.handler.inboundQueuedMessagesForTesting == 0 })
        // The refill's messages stay queued: the delegate holds them.
        f.delegate.hold()
        blocker.signal()
        refillGate.signal()
        // Runs after the refill and the hop.
        let (paused, queued) = try await onLoop(f) {
            (f.handler.isInboundReadPausedForTesting, f.handler.inboundQueuedMessagesForTesting)
        }
        #expect(queued == 6, "refilled past the bound")
        #expect(paused, "the resume re-read the counts and kept the pause")
        #expect(f.reads.count == readsBefore, "no read forwarded")
        // The refill drains in turn: then the read goes through.
        f.delegate.releaseAll()
        #expect(await waitUntil { !f.handler.isInboundReadPausedForTesting })
        try await drain(f.loop)
        #expect(f.reads.count == readsBefore + 1)
    }

    @Test("A disabled bound never withholds a read")
    func disabledBound() async throws {
        let f = try await makeFixture(bound: .disabled)
        let delivered = try await pump(f, messages(200))
        #expect(delivered.count == 200)
        #expect(!f.handler.isInboundReadPausedForTesting)
        f.delegate.releaseAll()
    }
}

@Suite("Inbound backlog bound configuration (#113)")
struct InboundBacklogBoundConfigurationTests {
    @Test("Defaults: 1024 messages and 4 MiB")
    func defaults() {
        let bound = NIOWebSocketServerConfiguration.inboundBacklogBound(environment: [:])
        #expect(bound == InboundBacklogBound.default)
        #expect(bound.maxMessages == 1024)
        #expect(bound.maxBytes == 4 << 20)
    }

    @Test("The env keys set each bound; 0 disables it")
    func environment() {
        let bound = NIOWebSocketServerConfiguration.inboundBacklogBound(environment: [
            "WS_INBOUND_BACKLOG_MAX_MESSAGES": "64",
            "WS_INBOUND_BACKLOG_MAX_BYTES": "0",
        ])
        #expect(bound == InboundBacklogBound(maxMessages: 64, maxBytes: 0))
    }

    @Test("A value that is set but invalid gives that bound's default", arguments: ["-1", "abc", ""])
    func invalidValues(raw: String) {
        let bound = NIOWebSocketServerConfiguration.inboundBacklogBound(environment: [
            "WS_INBOUND_BACKLOG_MAX_MESSAGES": raw,
            "WS_INBOUND_BACKLOG_MAX_BYTES": raw,
        ])
        #expect(bound == InboundBacklogBound.default)
        #expect(NIOWebSocketServerConfiguration.rejectedInboundBacklogKeys(environment: [
            "WS_INBOUND_BACKLOG_MAX_BYTES": raw,
        ]) == ["WS_INBOUND_BACKLOG_MAX_BYTES"])
    }

    @Test("The host configuration passes its bound to the WebSocket server")
    func hostPassesBound() {
        let bound = InboundBacklogBound(maxMessages: 12, maxBytes: 34)
        let host = NIOLandHostConfiguration(inboundBacklogBound: bound)
        #expect(host.webSocketServerConfiguration().inboundBacklogBound == bound)
    }

    @Test("The watermarks: above the bound pauses, half resumes; 0 is no bound")
    func watermarks() {
        let bound = InboundBacklogBound(maxMessages: 8, maxBytes: 100)
        #expect(!bound.isExceeded(messages: 8, bytes: 100))
        #expect(bound.isExceeded(messages: 9, bytes: 0))
        #expect(bound.isExceeded(messages: 0, bytes: 101))
        #expect(bound.isDrained(messages: 4, bytes: 50))
        #expect(!bound.isDrained(messages: 5, bytes: 0))
        #expect(!bound.isDrained(messages: 0, bytes: 51))
        #expect(!InboundBacklogBound.disabled.isExceeded(messages: .max, bytes: .max))
    }
}

// MARK: - Composition with the pending-join bound (4c)

@StateNodeBuilder
struct InboundBacklogLandState: StateNodeProtocol {
    @Sync(.broadcast)
    var joined: Int = 0
}

private struct FlipBlocked: Error {}

@Suite(
    "Inbound backlog bound and the pending-join bound (#113, 4c)",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: joins don't wait for a flip"),
    .timeLimit(.minutes(1))
)
struct InboundBacklogPendingJoinTests {
    @Test("A pending join and 300 frames: the adapter's bound closes it (JOIN_INBOUND_OVERFLOW), no read pause")
    func pendingJoinOverflowsFirst() async throws {
        let definition = Land("inbound-backlog", using: InboundBacklogLandState.self) {
            Rules {
                OnJoin { (state: inout InboundBacklogLandState, _: LandContext) in state.joined += 1 }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in InboundBacklogLandState() }
        )
        let manager = LandManager<InboundBacklogLandState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in InboundBacklogLandState() },
            transport: transport
        )
        let router = LandRouter<InboundBacklogLandState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)
        let landID = LandID(landType: "inbound-backlog", instanceId: "one")
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: InboundBacklogLandState(), metadata: [:])
        await container.transportAdapter.setSyncPlanFaultForTesting { throw FlipBlocked() }

        let reads = ReadCounter()
        let channel = await NIOAsyncTestingChannel()
        let handler = WebSocketSessionHandler(
            sessionID: SessionID("s-pending"),
            path: "/test",
            transport: transport,
            eventLoop: channel.eventLoop,
            // Below the adapter's 256: a router suspended in its handling would trip it.
            inboundBacklogBound: InboundBacklogBound(maxMessages: 64, maxBytes: 0),
            logger: Logger(label: "test")
        )
        try await channel.pipeline.addHandler(reads).get()
        try await channel.pipeline.addHandler(handler).get()
        let f = Fixture(channel: channel, handler: handler, reads: reads, delegate: BacklogDelegate())
        try await drain(f.loop)

        let join = String(decoding: try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1", landType: "inbound-backlog", landInstanceId: "one",
            playerID: "p1", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        )), as: UTF8.self)
        #expect(try await readOne(f, join))
        #expect(await waitUntilAsync { await router.isJoinPending(SessionID("s-pending")) }, "admitted, waiting for its flip")

        let action = String(decoding: try JSONEncoder().encode(TransportMessage.action(
            requestID: "a", action: ActionEnvelope(typeIdentifier: "Anything", payload: AnyCodable([String: Int]()))
        )), as: UTF8.self)
        // Read until 300 are sent, or a read doesn't get through: the session closed (the
        // adapter's bound) or, which must not happen, a read pause.
        // In chunks of 32, each delivered before the next: at most 32 queued while the router's
        // handling returns, and more, past 64, only if it were suspended.
        var sent = 0
        while sent < 300, try await readOne(f, action) {
            sent += 1
            if sent % 32 == 0 { await handler.waitForInboundIdle() }
        }
        #expect(sent > 256, "past the adapter's 256-frame bound: \(sent)")

        // The adapter's pending-join bound (256 frames) ends the join: its error, then the close.
        var codes: [String] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while !codes.contains(ErrorCode.joinInboundOverflow.rawValue), ContinuousClock.now < deadline {
            if let frame = try await channel.readOutbound(as: WebSocketFrame.self) {
                if let message = try? JSONDecoder().decode(TransportMessage.self, from: Data(frame.unmaskedData.readableBytesView)),
                   case .error(let payload) = message.payload {
                    codes.append(payload.code)
                }
            } else {
                try? await safeTaskSleep(for: .milliseconds(2))
            }
        }
        #expect(codes.contains(ErrorCode.joinInboundOverflow.rawValue), "codes: \(codes)")
        let stats = try await onLoop(f) { f.handler.inboundBacklog }
        #expect(stats.readPauses == 0, "the chain bound never trips while the router returns")
        #expect(stats.maxQueuedMessages <= 300)
    }
}

private func waitUntilAsync(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(2))
    }
    return await condition()
}
