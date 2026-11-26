// Tests/SwiftStateTreeTransportTests/SupersedeCloseOrderTests.swift
//
// A newer join of a player supersedes its older session and closes it with 4017 (#531, #861).
// The close goes through the outbound writer, behind the frames already queued for the old
// session, so it can't overtake them (#909). Before, it was a detached `closeSession`, which
// retires the session's queue at once and drops a frame still in it.

import Foundation
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
