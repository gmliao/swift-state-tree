// Tests/SwiftStateTreeTransportTests/JoinPendingInboundTests.swift
//
// Frames a client sends while its in-turn join waits for the flip (#69, join PR 4c): the router
// returns after the admission (`.joinPending`), the adapter defers the frames, and a drain
// applies them after OnJoin, in order, within a bound. Interleavings are forced with the sync
// plan fault (no flip until a test clears it) and hold points, never timing.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct PendingInboundState: StateNodeProtocol {
    @Sync(.broadcast)
    var log: [String] = []
}

@Payload
struct PendingTagAction: ActionPayload {
    typealias Response = PendingTagResponse
    let tag: String
}

@Payload
struct PendingTagResponse: ResponsePayload {
    let count: Int
}

/// Records each frame sent and the close, in one ordered log.
private actor PendingConnection: WebSocketConnection {
    enum Entry: Equatable {
        case frame(Data)
        case close
    }

    private(set) var entries: [Entry] = []
    /// While set, `send` waits on it (a client that stopped reading).
    var stall: TestGate?

    func setStall(_ gate: TestGate?) { stall = gate }

    func send(_ data: Data) async throws {
        if let stall { await stall.arrive() }
        entries.append(.frame(data))
    }

    func close() async throws { entries.append(.close) }

    var closed: Bool { entries.contains(.close) }

    var frames: [Data] {
        entries.compactMap { if case .frame(let data) = $0 { return data } else { return nil } }
    }

    /// The decoded messages, JSON frames only.
    var messages: [TransportMessage] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
    }

    var errorCodes: [String] {
        messages.compactMap { if case .error(let payload) = $0.payload { return payload.code } else { return nil } }
    }
}

private func pendingPoll(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(5))
    }
    return await condition()
}

private struct PendingFlipBlocked: Error {}

/// A router, its transport and one land, with a session connected.
private struct PendingHarness {
    let transport: WebSocketTransport
    let router: LandRouter<PendingInboundState>
    let container: LandContainer<PendingInboundState>
    let session = SessionID("s-pending")
    let connection = PendingConnection()

    var adapter: TransportAdapter<PendingInboundState> { container.transportAdapter }

    let encoding: TransportEncodingConfig

    static func make(encoding: TransportEncodingConfig = .json) async throws -> PendingHarness {
        let definition = Land("pending-inbound", using: PendingInboundState.self) {
            Rules {
                OnJoin { (state: inout PendingInboundState, _: LandContext) in
                    state.log.append("joined")
                }
                HandleAction(PendingTagAction.self) { (state: inout PendingInboundState, action: PendingTagAction, _: LandContext) in
                    state.log.append(action.tag)
                    return PendingTagResponse(count: state.log.count)
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in PendingInboundState() }
        )
        let manager = LandManager<PendingInboundState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in PendingInboundState() },
            transport: transport,
            transportEncoding: encoding
        )
        let router = LandRouter<PendingInboundState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true,
            transportEncoding: encoding
        )
        await transport.setDelegate(router)
        let landID = LandID(landType: "pending-inbound", instanceId: "one")
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: PendingInboundState(), metadata: [:])
        let harness = PendingHarness(transport: transport, router: router, container: container, encoding: encoding)
        await transport.handleConnection(sessionID: harness.session, connection: harness.connection, authInfo: nil)
        return harness
    }

    /// Sends the join with the flip blocked; returns once the router has returned (pending).
    func joinPending() async throws {
        await adapter.setSyncPlanFaultForTesting { throw PendingFlipBlocked() }
        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1", landType: "pending-inbound", landInstanceId: "one",
            playerID: "p1", deviceID: nil, metadata: nil
        ))
        await transport.handleIncomingMessage(sessionID: session, data: join)
        #expect(await router.isJoinPending(session), "the router returned after the admission")
        #expect(await pendingPoll { await container.keeper.currentState().log == ["joined"] }, "OnJoin ran")
    }

    func send(_ tag: String) async throws {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: PendingTagAction.self), payload: AnyCodable(PendingTagAction(tag: tag)))
        // The codec's map form: MessagePack frames on a MessagePack land, JSON on a JSON one.
        let data = try encoding.makeCodec().encode(TransportMessage.action(requestID: "a-\(tag)", action: envelope))
        await transport.handleIncomingMessage(sessionID: session, data: data)
    }

    /// Lets the flip happen.
    func flip() async {
        await adapter.setSyncPlanFaultForTesting(nil)
        await adapter.syncNow()
    }

    var log: [String] {
        get async { await container.keeper.currentState().log }
    }
}

@Suite(
    "Frames of a session whose join waits for its flip (#69)",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: joins don't complete in a turn")
)
struct JoinPendingInboundTests {
    @Test("Frames sent during the join are applied after OnJoin, in order, after the JoinResponse")
    func framesDuringJoinApplyAfterOnJoin() async throws {
        let h = try await PendingHarness.make()
        try await h.joinPending()
        for tag in ["a", "b", "c"] { try await h.send(tag) }
        #expect(await h.adapter.inboundDeferredForJoiningSessions == 3)
        #expect(await h.log == ["joined"], "nothing is applied before the flip")

        await h.flip()
        #expect(await pendingPoll { await h.log == ["joined", "a", "b", "c"] })
        #expect(await pendingPoll { await !h.router.isJoinPending(h.session) })
        #expect(await h.adapter.inboundAfterFlipCount(h.session) == nil, "the drain entry is gone once empty")

        // The JoinResponse precedes every action response.
        #expect(await pendingPoll { await h.connection.messages.filter { $0.kind == .actionResponse }.count == 3 })
        let kinds = await h.connection.messages.map(\.kind).filter { $0 == .joinResponse || $0 == .actionResponse }
        #expect(kinds.first == .joinResponse)
    }

    @Test("MessagePack: frames sent during the join are applied after OnJoin, in order")
    func framesDuringJoinMessagePack() async throws {
        let h = try await PendingHarness.make(encoding: .messagepack)
        try await h.joinPending()
        for tag in ["a", "b", "c"] { try await h.send(tag) }
        #expect(await h.adapter.inboundDeferredForJoiningSessions == 3)
        #expect(await h.log == ["joined"])
        await h.flip()
        #expect(await pendingPoll { await h.log == ["joined", "a", "b", "c"] })
        #expect(await h.connection.frames.first.map { $0.first == UInt8(ascii: "{") } == true, "the JoinResponse is JSON")
        #expect(await h.connection.frames.dropFirst().allSatisfy { $0.first != UInt8(ascii: "{") }, "later frames are MessagePack")
    }

    @Test("A frame right after the JoinResponse, while the router is still pending, is applied at once")
    func frameAfterJoinResponseWhilePending() async throws {
        let h = try await PendingHarness.make()
        try await h.joinPending()
        let gate = TestGate()
        await h.router.installHolds(HoldRegistry<LandRouterHoldPoint>().on(.flipWaitResumed) { await gate.arrive() }.hook)
        await h.flip()
        #expect(await gate.waitForArrivals(1))
        #expect(await pendingPoll { await h.connection.messages.contains { $0.kind == .joinResponse } })
        #expect(await h.router.isJoinPending(h.session))
        // Flipped, nothing deferred: the adapter dispatches it inline although the router hasn't
        // marked the session joined yet.
        try await h.send("x")
        #expect(await h.log == ["joined", "x"])
        gate.open()
        #expect(await pendingPoll { await !h.router.isJoinPending(h.session) })
    }

    @Test("A frame sent while its drain dispatches the first deferred one waits behind the rest")
    func orderAcrossTheFlip() async throws {
        let h = try await PendingHarness.make()
        try await h.joinPending()
        for tag in ["a", "b"] { try await h.send(tag) }
        let gate = TestGate()
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.inboundDrainDispatch, arrival: 1) { await gate.arrive() }.hook)
        await h.flip()
        #expect(await gate.waitForArrivals(1))
        // Flipped and draining: the new frame is queued behind "b", never dispatched inline.
        try await h.send("late")
        #expect(await h.adapter.inboundAfterFlipCount(h.session) == 2)
        #expect(await h.log == ["joined"])
        gate.open()
        #expect(await pendingPoll { await h.log == ["joined", "a", "b", "late"] })
    }

    @Test("Over the frame count before the flip, the join fails with JOIN_INBOUND_OVERFLOW and the session closes")
    func boundBeforeFlipCount() async throws {
        let h = try await PendingHarness.make()
        await h.adapter.setDeferredInboundLimitForTesting(count: 2, bytes: 1 << 20)
        try await h.joinPending()
        for tag in ["a", "b", "c"] { try await h.send(tag) }
        try await expectJoinInboundOverflow(h, dropped: 3)
    }

    @Test("Over the byte bound before the flip, the join fails the same way")
    func boundBeforeFlipBytes() async throws {
        let h = try await PendingHarness.make()
        // One action frame fits, two don't.
        await h.adapter.setDeferredInboundLimitForTesting(count: 100, bytes: 150)
        try await h.joinPending()
        for tag in ["a", "b"] { try await h.send(tag) }
        try await expectJoinInboundOverflow(h, dropped: 2)
    }

    private func expectJoinInboundOverflow(_ h: PendingHarness, dropped: Int) async throws {
        #expect(await pendingPoll { await h.connection.closed }, "the session is closed")
        #expect(await h.connection.errorCodes == [ErrorCode.joinInboundOverflow.rawValue])
        // The error frame was handed over before the close.
        let entries = await h.connection.entries
        #expect(entries.last == .close)
        #expect(await h.adapter.inTurnJoinFailures[.inboundOverflow] == 1)
        #expect(await h.adapter.inboundDroppedForJoiningSessions == dropped)
        #expect(await h.router.getBoundLandID(for: h.session) == nil)
        #expect(await pendingPoll { await h.container.keeper.playerCount() == 0 }, "the cleanup removed the keeper's player")
        #expect(await pendingPoll { await !h.adapter.isJoining(h.session) })
        // A frame after the failure reaches nothing.
        try await h.send("after")
        #expect(await !h.log.contains("after"))
    }

    @Test("Over the bound after the flip, the session gets INBOUND_OVERFLOW and is closed")
    func boundAfterFlip() async throws {
        let h = try await PendingHarness.make()
        await h.adapter.setDeferredInboundLimitForTesting(count: 2, bytes: 1 << 20)
        try await h.joinPending()
        for tag in ["a", "b"] { try await h.send(tag) }
        let gate = TestGate()
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.inboundDrainDispatch, arrival: 1) { await gate.arrive() }.hook)
        await h.flip()
        #expect(await gate.waitForArrivals(1))
        // "a" is being dispatched, "b" waits: one more fits, the next goes over.
        try await h.send("c")
        try await h.send("d")
        #expect(await pendingPoll { await h.connection.closed })
        #expect(await h.connection.errorCodes.contains(ErrorCode.inboundOverflow.rawValue))
        #expect(await h.adapter.inboundOverflowClosures == 1)
        #expect(await h.adapter.inboundAfterFlipCount(h.session) == nil)
        gate.open()
        #expect(await pendingPoll { await !h.adapter.isJoined(sessionID: h.session) })
        #expect(await !h.log.contains("d"))
    }

    @Test("A disconnect while pending fails the join, drops the deferred frames, and leaves no router state")
    func disconnectWhilePending() async throws {
        let h = try await PendingHarness.make()
        try await h.joinPending()
        for tag in ["a", "b"] { try await h.send(tag) }
        await h.transport.handleDisconnection(sessionID: h.session)
        #expect(await pendingPoll { await h.adapter.inTurnJoinFailures[.disconnected] == 1 })
        #expect(await pendingPoll { await h.adapter.inboundDroppedForJoiningSessions == 2 })
        #expect(await !h.router.isJoinPending(h.session))
        #expect(await h.router.getBoundLandID(for: h.session) == nil)
        await h.flip()
        #expect(await pendingPoll { await h.container.keeper.playerCount() == 0 })
        #expect(await h.log == ["joined"], "the deferred frames were never applied")
        #expect(await h.connection.errorCodes.isEmpty, "no response to a client that left")
    }

    @Test("A disconnect during the drain stops it; the frames it still held are dropped")
    func disconnectDuringDrain() async throws {
        let h = try await PendingHarness.make()
        try await h.joinPending()
        for tag in ["a", "b", "c"] { try await h.send(tag) }
        let gate = TestGate()
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.inboundDrainDispatch, arrival: 1) { await gate.arrive() }.hook)
        await h.flip()
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: h.session)
        #expect(await pendingPoll { await !h.adapter.isJoined(sessionID: h.session) })
        gate.open()
        #expect(await pendingPoll { await h.adapter.inboundAfterFlipCount(h.session) == nil })
        // "a" was popped before the disconnect; "b" and "c" were not applied.
        let log = await h.log
        #expect(!log.contains("b") && !log.contains("c"))
        #expect(await h.adapter.inboundDroppedForJoiningSessions == 2)
    }
}
