// Tests/SwiftStateTreeTransportTests/SupersedeCloseOrderTests.swift
//
// A newer join of a player supersedes its older session and closes it with 4017 (#531, #861).
// The close goes through the outbound writer, behind the frames already queued for the old
// session, so it can't overtake them (#909). Before, it was a detached `closeSession`, which
// retires the session's queue at once and drops a frame still in it.

import Foundation
import Logging
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// A connection whose sends can be held, recording what it got in order.
private actor HeldSendConnection: WebSocketConnection {
    enum Event: Equatable, Sendable {
        case sent(Data)
        case closed(UInt16)
    }

    private(set) var events: [Event] = []
    private(set) var sendAttempts = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Arrives once per send attempt, before the hold.
    let attempted = TestGate()
    /// Arrives once per close.
    let closedSignal = TestGate()

    init() {
        attempted.open()
        closedSignal.open()
    }

    func holdSends() { holding = true }

    func releaseSends() {
        holding = false
        let resumed = held
        held = []
        for continuation in resumed { continuation.resume() }
    }

    func send(_ data: Data, kind: WebSocketFrameKind) async throws {
        sendAttempts += 1
        await attempted.arrive()
        if holding { await withCheckedContinuation { held.append($0) } }
        events.append(.sent(data))
    }

    func close() async throws { await record(1000) }
    func close(with close: SessionClose) async throws { await record(close.code) }

    private func record(_ code: UInt16) async {
        events.append(.closed(code))
        await closedSignal.arrive()
    }

    var closes: [UInt16] {
        events.compactMap { if case .closed(let code) = $0 { code } else { nil } }
    }
}

/// A land, its adapter and a `WebSocketTransport` whose sessions the test connects. The
/// transport has no delegate: the test registers each session with the adapter itself.
private struct SupersedeFixture {
    let keeper: LandKeeper<RegisterSessionTestState>
    let adapter: TransportAdapter<RegisterSessionTestState>
    let transport: WebSocketTransport
    let player = PlayerID("p1")

    init() async {
        let definition = Land("supersede-close-order", using: RegisterSessionTestState.self) {
            Rules {
                OnJoin { state, _ in state.joins += 1 }
            }
        }
        transport = WebSocketTransport()
        keeper = LandKeeper(definition: definition, initialState: RegisterSessionTestState(), autoStartLoops: false)
        adapter = TransportAdapter<RegisterSessionTestState>(keeper: keeper, transport: transport, landID: "supersede-close-order")
        await keeper.setTransport(adapter)
    }

    /// Connects `session`, joins it in the keeper as the player and registers it with its
    /// connection's generation; returns the generation once the writer is idle and, with
    /// `flushes`, every transport queue has sent what it held (a held send never does).
    @discardableResult
    func join(_ session: SessionID, _ client: ClientID, _ connection: HeldSendConnection, flushes: Bool = true) async throws -> UInt64 {
        _ = await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        let generation = try #require(await transport.connectionGeneration(for: session))
        _ = try await keeper.join(
            session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, services: LandServices()
        )
        await adapter.onConnect(sessionID: session, clientID: client)
        await adapter.registerSession(
            sessionID: session, clientID: client, playerID: player, authInfo: nil, connectionGeneration: generation
        )
        await adapter.waitForOutboundIdleForTesting()
        if flushes { await transport.flushSessionQueues() }
        return generation
    }
}

/// Records each ordered close with its code and each at-once close, as "<session>@<generation>".
private actor OrderedCloseRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var closes: [String] = []
    private(set) var orderedCloses: [String] = []
    let closeSignal = TestGate()

    init() { closeSignal.open() }

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        closes.append("\(Self.label(sessionID, generation)):\(close.code)")
        await closeSignal.arrive()
    }
    func closeSessionAfterQueuedFrames(_ sessionID: SessionID, generation: UInt64?, with close: SessionClose) async {
        orderedCloses.append("\(Self.label(sessionID, generation)):\(close.code)")
        await closeSignal.arrive()
    }
    nonisolated var supportsCloseSession: Bool { true }

    static func label(_ sessionID: SessionID, _ generation: UInt64?) -> String {
        "\(sessionID.rawValue)@\(generation.map(String.init) ?? "any")"
    }
}

/// Records the writer's calls in order, as "frame <session>" and "ordered <session>:<code>".
/// A `sendSessionFrames` with a frame for a held session waits at the gate, and so does the
/// ordered close while closes are held: the writer's consumer stops inside that element.
private actor GatedWriterTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var events: [String] = []
    private var heldSessions: Set<SessionID> = []
    private var holdsCloses = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Arrives when a held call starts waiting.
    let entered = TestGate()
    /// Arrives once per close, ordered or at once.
    let closeSignal = TestGate()

    init() {
        entered.open()
        closeSignal.open()
    }

    func hold(_ sessionID: SessionID) { heldSessions.insert(sessionID) }
    func holdCloses() { holdsCloses = true }

    func release() {
        heldSessions = []
        holdsCloses = false
        let resumed = held
        held = []
        for continuation in resumed { continuation.resume() }
    }

    private func wait() async {
        await entered.arrive()
        await withCheckedContinuation { held.append($0) }
    }

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendSessionFrames(_ frames: [SessionFrame]) async {
        if frames.contains(where: { heldSessions.contains($0.sessionID) }) { await wait() }
        events += frames.map { "frame \($0.sessionID.rawValue)" }
    }
    func closeSessionAfterQueuedFrames(_ sessionID: SessionID, generation: UInt64?, with close: SessionClose) async {
        if holdsCloses { await wait() }
        events.append("ordered \(sessionID.rawValue):\(close.code)")
        await closeSignal.arrive()
    }
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        events.append("at once \(sessionID.rawValue):\(close.code)")
        await closeSignal.arrive()
    }
    nonisolated var supportsCloseSession: Bool { true }
}

/// A transport written before #909: only the two-argument ordered close, and the at-once one.
private actor TwoArgumentOrderedTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var calls: [String] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        calls.append("at once \(close.code)")
    }
    func closeSessionAfterQueuedFrames(_ sessionID: SessionID, generation: UInt64?) async {
        calls.append("ordered")
    }
    nonisolated var supportsCloseSession: Bool { true }
}

@Suite("A superseded session's close waits behind its queued frames (#909)", .timeLimit(.minutes(1)))
struct SupersedeCloseOrderTests {
    let a = SessionID("a"), ca = ClientID("ca")
    let a2 = SessionID("a2"), ca2 = ClientID("ca2")

    @Test("A frame queued for the old session reaches it before its 4017 close, and the close runs at its marker")
    func queuedFrameBeforeClose() async throws {
        let f = await SupersedeFixture()
        await f.adapter.trackDetachedClosesForTesting()
        // The bound of the ordered close (1 s) is held: "no close while held" can't race it.
        let bound = await f.transport.holdBoundClosesForTesting()
        defer { bound.open() }
        let old = HeldSendConnection()
        try await f.join(a, ca, old)
        let before = await old.sendAttempts

        // A's last frame, queued in the writer, is held at A's connection.
        await old.holdSends()
        let last = Data("a's last frame".utf8)
        let frame = await f.adapter.sessionFrame(last, kind: .text, to: a)
        let result = await f.adapter.outboundWriter.enqueue([frame])
        #expect(result == .accepted)
        #expect(await old.attempted.waitForArrivals(before + 1), "the frame reached the connection's send")

        // A2 supersedes A. Every close the supersede started has run, and the writer has handed
        // its elements to the transport; still no close while the frame is held. (A detached
        // `closeSession` would have closed A by now.)
        try await f.join(a2, ca2, HeldSendConnection(), flushes: false)
        await f.adapter.waitForDetachedClosesForTesting()
        await f.adapter.waitForOutboundIdleForTesting()
        #expect(await old.closes.isEmpty, "A was closed while its last frame was held")

        await old.releaseSends()
        #expect(await old.closedSignal.waitForArrivals(1))
        let events = await old.events
        #expect(events.suffix(2) == [.sent(last), .closed(SessionClose.Code.superseded)], "\(events.suffix(2))")
        #expect(await f.transport.finalFrameClosesAtBound == 0, "the close ran at the bound, not at its marker")
        await f.keeper.forceShutdown()
    }

    @Test("The supersede's close goes through the transport's ordered close, with 4017 and the old connection's generation")
    func orderedCloseCarriesCodeAndGeneration() async throws {
        let definition = Land("supersede-close-order", using: RegisterSessionTestState.self) { Rules {} }
        let transport = OrderedCloseRecordingTransport()
        let keeper = LandKeeper(definition: definition, initialState: RegisterSessionTestState(), autoStartLoops: false)
        let adapter = TransportAdapter<RegisterSessionTestState>(keeper: keeper, transport: transport, landID: "supersede-close-order")
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        for (session, client, generation) in [(a, ca, UInt64(5)), (a2, ca2, UInt64(6))] {
            _ = try await keeper.join(
                session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]),
                clientID: client, sessionID: session, services: LandServices()
            )
            await adapter.onConnect(sessionID: session, clientID: client)
            await adapter.registerSession(sessionID: session, clientID: client, playerID: PlayerID("p1"), authInfo: nil, connectionGeneration: generation)
        }
        #expect(await transport.closeSignal.waitForArrivals(1))
        await adapter.waitForOutboundIdleForTesting()
        #expect(await transport.orderedCloses == ["a@5:\(SessionClose.Code.superseded)"])
        #expect(await transport.closes.isEmpty)
        await keeper.forceShutdown()
    }

    @Test("Through any Transport, WebSocketTransport's ordered close keeps its code; an older transport keeps its ordered close for a plain close")
    func orderedCloseDispatch() async throws {
        let transport = WebSocketTransport()
        let bound = await transport.holdBoundClosesForTesting()
        defer { bound.open() }
        let connection = HeldSendConnection()
        _ = await transport.handleConnection(sessionID: a, connection: connection, authInfo: nil)
        let generation = try #require(await transport.connectionGeneration(for: a))
        await connection.holdSends()
        let frame = Data("queued".utf8)
        await transport.sendSessionFrames([SessionFrame(data: frame, sessionID: a, connectionGeneration: generation)])
        #expect(await connection.attempted.waitForArrivals(1))
        // The writer's call: through the existential, with the code.
        let existential: any Transport = transport
        await existential.closeSessionAfterQueuedFrames(a, generation: generation, with: .superseded)
        #expect(await connection.closes.isEmpty, "the close overtook the held frame")
        await connection.releaseSends()
        #expect(await connection.closedSignal.waitForArrivals(1))
        #expect(await connection.events == [.sent(frame), .closed(SessionClose.Code.superseded)])

        // The default: `.normal` takes the older ordered close; another code closes at once.
        let older = TwoArgumentOrderedTransport()
        let olderExistential: any Transport = older
        await olderExistential.closeSessionAfterQueuedFrames(a, generation: 1, with: .normal)
        await olderExistential.closeSessionAfterQueuedFrames(a, generation: 1, with: .superseded)
        #expect(await older.calls == ["ordered", "at once \(SessionClose.Code.superseded)"])
    }

    @Test("The close waits in the writer behind A's held frame element, and reaches the transport after it")
    func closeWaitsInTheWriter() async throws {
        let definition = Land("supersede-close-order", using: RegisterSessionTestState.self) { Rules {} }
        let transport = GatedWriterTransport()
        let keeper = LandKeeper(definition: definition, initialState: RegisterSessionTestState(), autoStartLoops: false)
        let adapter = TransportAdapter<RegisterSessionTestState>(keeper: keeper, transport: transport, landID: "supersede-close-order")
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        func join(_ session: SessionID, _ client: ClientID, generation: UInt64) async throws {
            _ = try await keeper.join(
                session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]),
                clientID: client, sessionID: session, services: LandServices()
            )
            await adapter.onConnect(sessionID: session, clientID: client)
            await adapter.registerSession(sessionID: session, clientID: client, playerID: PlayerID("p1"), authInfo: nil, connectionGeneration: generation)
        }
        try await join(a, ca, generation: 5)
        await adapter.waitForOutboundIdleForTesting()

        // The writer's consumer stops inside the element with A's last frame.
        await transport.hold(a)
        let frame = await adapter.sessionFrame(Data("a's last frame".utf8), kind: .text, to: a)
        let writer = await adapter.outboundWriter
        #expect(writer.enqueue([frame]) == .accepted)
        #expect(await transport.entered.waitForArrivals(1))

        // A2 supersedes A. The close is a writer element behind the held one: it hasn't reached
        // the transport. (A close sent to the transport around the writer has no element here.)
        try await join(a2, ca2, generation: 6)
        await adapter.waitForDetachedClosesForTesting()
        #expect(writer.closeOnlyElements == 1, "the close isn't queued in the writer")
        #expect(await !transport.events.contains { $0.hasPrefix("ordered") || $0.hasPrefix("at once") })

        await transport.release()
        #expect(await transport.closeSignal.waitForArrivals(1))
        await adapter.waitForOutboundIdleForTesting()
        let events = await transport.events
        let lastFrame = try #require(events.lastIndex(of: "frame a"))
        let close = try #require(events.firstIndex(of: "ordered a:\(SessionClose.Code.superseded)"), "\(events)")
        #expect(lastFrame < close, "\(events)")
        await keeper.forceShutdown()
    }

    @Test("A queued close-only element leaves the empty-backlog allowance to the next large frame")
    func closeOnlyElementKeepsTheAllowance() async throws {
        let transport = GatedWriterTransport()
        await transport.holdCloses()
        let writer = OutboundWriter(transport: transport, maxBytes: 4, logger: Logger(label: "supersede-close-order"))
        #expect(writer.enqueueClose([ClosingSession(sessionID: a, generation: 1, close: .superseded)]) == .accepted)
        // The consumer is inside the close: the element is still queued.
        #expect(await transport.entered.waitForArrivals(1))
        #expect(writer.closeOnlyElements == 1)
        #expect(writer.backlog.elements == 1)
        // Over the ceiling, but no frame is queued: accepted. The next one isn't.
        let large = SessionFrame(data: Data(count: 16), sessionID: a2, connectionGeneration: nil)
        #expect(writer.enqueue([large]) == .accepted)
        #expect(writer.enqueue([large]) == .droppedOverCeiling)
        await transport.release()
        await writer.waitForIdle()
        #expect(writer.closeOnlyElements == 0)
        #expect(await transport.events == ["ordered a:\(SessionClose.Code.superseded)", "frame a2"])
    }

    @Test("With the writer finished, the supersede still closes the old session, at once")
    func finishedWriterFallsBack() async throws {
        let definition = Land("supersede-close-order", using: RegisterSessionTestState.self) { Rules {} }
        let transport = OrderedCloseRecordingTransport()
        let keeper = LandKeeper(definition: definition, initialState: RegisterSessionTestState(), autoStartLoops: false)
        let adapter = TransportAdapter<RegisterSessionTestState>(keeper: keeper, transport: transport, landID: "supersede-close-order")
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        for (index, (session, client, generation)) in [(a, ca, UInt64(5)), (a2, ca2, UInt64(6))].enumerated() {
            _ = try await keeper.join(
                session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]),
                clientID: client, sessionID: session, services: LandServices()
            )
            await adapter.onConnect(sessionID: session, clientID: client)
            if index == 1 {
                // Nothing more can be written: the writer refuses the close element.
                let writer = await adapter.outboundWriter
                #expect(await writer.finish(timeout: .seconds(10)))
                #expect(writer.isFinished)
            }
            await adapter.registerSession(sessionID: session, clientID: client, playerID: PlayerID("p1"), authInfo: nil, connectionGeneration: generation)
        }
        #expect(await transport.closeSignal.waitForArrivals(1))
        #expect(await transport.closes == ["a@5:\(SessionClose.Code.superseded)"])
        #expect(await transport.orderedCloses.isEmpty)
        await keeper.forceShutdown()
    }
}

// MARK: - #911: the first close decided for a connection is the one it gets

@Suite("The first close decided for a connection is the one it gets (#911)", .timeLimit(.minutes(1)))
struct CloseDecisionOrderTests {
    let a = SessionID("a"), ca = ClientID("ca")
    let a2 = SessionID("a2"), ca2 = ClientID("ca2")
    let error = Data("a's error".utf8)

    /// A joined as `old`, with a last frame queued in the writer and held at its connection's send.
    private func joinWithHeldFrame(_ f: SupersedeFixture, _ old: HeldSendConnection) async throws -> (generation: UInt64, last: Data) {
        let generation = try await f.join(a, ca, old)
        let before = await old.sendAttempts
        await old.holdSends()
        let last = Data("a's last frame".utf8)
        let frame = await f.adapter.sessionFrame(last, kind: .text, to: a)
        #expect(await f.adapter.outboundWriter.enqueue([frame]) == .accepted)
        #expect(await old.attempted.waitForArrivals(before + 1), "the frame reached the connection's send")
        return (generation, last)
    }

    @Test("An ended session's final frame doesn't overtake the supersede's pending 4017")
    func endedFinalFrameKeepsThePendingClose() async throws {
        let f = await SupersedeFixture()
        await f.adapter.trackDetachedClosesForTesting()
        let bound = await f.transport.holdBoundClosesForTesting()
        defer { bound.open() }
        let old = HeldSendConnection()
        let (generation, last) = try await joinWithHeldFrame(f, old)
        // A2 supersedes A: its 4017 waits behind the held frame. Then the router's final frame
        // for A, a join failure it decided before the supersede, finds A ended.
        try await f.join(a2, ca2, HeldSendConnection(), flushes: false)
        await f.adapter.sendFinalFrameAndClose(error, kind: .text, to: a, generation: generation)
        await f.adapter.waitForDetachedClosesForTesting()
        await f.adapter.waitForOutboundIdleForTesting()
        #expect(await old.closes.isEmpty, "a close overtook A's held frame")

        await old.releaseSends()
        #expect(await old.closedSignal.waitForArrivals(1))
        await f.adapter.waitForOutboundIdleForTesting()
        let events = await old.events
        #expect(events.suffix(2) == [.sent(last), .closed(SessionClose.Code.superseded)], "\(events.suffix(2))")
        #expect(await old.closes == [SessionClose.Code.superseded], "one close, the first decided")
        await f.keeper.forceShutdown()
    }

    @Test("An ended session's final frame, with the old connection's generation, leaves a new connection under the ID open")
    func endedFinalFrameSparesAReusedID() async throws {
        let f = await SupersedeFixture()
        let first = HeldSendConnection()
        let generation = try await f.join(a, ca, first)
        // A2 supersedes A, and A's 4017 goes out.
        try await f.join(a2, ca2, HeldSendConnection())
        #expect(await first.closedSignal.waitForArrivals(1))
        #expect(await first.closes == [SessionClose.Code.superseded])
        // A's client goes, and a new connection takes the ID: the transport accepted it, the
        // adapter hasn't registered it, so the adapter still has A as ended.
        await f.transport.handleDisconnection(sessionID: a)
        let reused = HeldSendConnection()
        _ = await f.transport.handleConnection(sessionID: a, connection: reused, authInfo: nil)
        let reusedGeneration = try #require(await f.transport.connectionGeneration(for: a))
        #expect(reusedGeneration != generation)

        // The router's final frame for the old connection.
        await f.adapter.sendFinalFrameAndClose(error, kind: .text, to: a, generation: generation)
        await f.adapter.waitForOutboundIdleForTesting()
        // A frame for the new connection still goes out: no close marker is on its queue.
        let dropsBefore = await f.transport.framesDroppedAfterCloseMarker
        await f.transport.sendSessionFrames([SessionFrame(data: Data("hello".utf8), sessionID: a, connectionGeneration: reusedGeneration)])
        await f.transport.flushSessionQueues()
        #expect(await f.transport.framesDroppedAfterCloseMarker == dropsBefore)
        #expect(await reused.events == [.sent(Data("hello".utf8))])
        #expect(await reused.closes.isEmpty, "the old connection's close closed the new one")
        await f.keeper.forceShutdown()
    }

    @Test("A pending final frame's close keeps its place: a later supersede's 4017 is ignored")
    func pendingFinalFrameWinsOverALaterSupersede() async throws {
        let f = await SupersedeFixture()
        let bound = await f.transport.holdBoundClosesForTesting()
        defer { bound.open() }
        let old = HeldSendConnection()
        let (generation, last) = try await joinWithHeldFrame(f, old)
        // The first decision: A's final frame and its plain close, behind the held frame (the
        // post-flip inbound overflow's call; A is still a member). Then A2 supersedes A.
        await f.adapter.sendFinalFrameAndClose(error, kind: .text, to: a, generation: generation)
        try await f.join(a2, ca2, HeldSendConnection(), flushes: false)
        await f.adapter.waitForOutboundIdleForTesting()
        #expect(await old.closes.isEmpty)

        await old.releaseSends()
        #expect(await old.closedSignal.waitForArrivals(1))
        let events = await old.events
        #expect(events.suffix(3) == [.sent(last), .sent(error), .closed(1000)], "\(events.suffix(3))")
        #expect(await old.closes == [1000], "one close, the first decided")
        await f.keeper.forceShutdown()
    }

    @Test("An at-once close preempts a pending ordered one: a member's pending final frame, then the land failure's 4016")
    func landFailurePreemptsAPendingFinalFrame() async throws {
        let f = await SupersedeFixture()
        let bound = await f.transport.holdBoundClosesForTesting()
        defer { bound.open() }
        let old = HeldSendConnection()
        let (generation, _) = try await joinWithHeldFrame(f, old)
        // The first decision, as the post-flip inbound overflow makes it: A stays a member.
        await f.adapter.sendFinalFrameAndClose(error, kind: .text, to: a, generation: generation)
        #expect(await f.adapter.isJoined(sessionID: a), "the staged first decision must leave A a member")
        // The second, at once: every session the adapter holds, A included.
        await f.adapter.closeSessionsForLandFailure(
            LandFailure(kind: .syncPlan, detail: "#911's F3", position: LandFailurePosition(stage: .syncPhase))
        )
        #expect(await old.closes == [SessionClose.Code.landFailed], "4016 while A's frame is held")
        await old.releaseSends()
        await f.adapter.waitForOutboundIdleForTesting()
        #expect(await !old.events.contains(.sent(error)), "the error went out after the 4016")
        #expect(await old.closes == [SessionClose.Code.landFailed])
        await f.keeper.forceShutdown()
    }
}
