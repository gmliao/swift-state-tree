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

/// Sent by OnJoin to the joiner (a held targeted event).
@Payload
struct PendingJoinEvent: ServerEventPayload {
    let note: String
}

/// Sent by `PendingTagAction` to its sender.
@Payload
struct PendingActionEvent: ServerEventPayload {
    let tag: String
}

/// An action whose resolver waits at `pendingResolverGate`, if one is set: a drained action
/// suspended inside its dispatch.
@Payload
struct PendingGatedAction: ActionPayload {
    typealias Response = PendingTagResponse
    let tag: String
}

struct PendingGateOutput: ResolverOutput {}

/// The gate `PendingGateResolver` waits at (one test sets it; the suite's tests don't share it).
private final class PendingResolverGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: TestGate?

    var current: TestGate? {
        get { lock.lock(); defer { lock.unlock() }; return gate }
        set { lock.lock(); gate = newValue; lock.unlock() }
    }
}

private let pendingResolverGate = PendingResolverGate()

struct PendingGateResolver: ContextResolver {
    typealias Output = PendingGateOutput

    static func resolve(ctx: ResolverContext) async throws -> PendingGateOutput {
        await pendingResolverGate.current?.arrive()
        return PendingGateOutput()
    }
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
            ServerEvents {
                Register(PendingJoinEvent.self)
                Register(PendingActionEvent.self)
            }
            Rules {
                OnJoin { (state: inout PendingInboundState, ctx: LandContext) in
                    state.log.append("joined")
                    ctx.emitEvent(PendingJoinEvent(note: "onJoin"), to: .session(ctx.sessionID))
                }
                HandleAction(PendingTagAction.self) { (state: inout PendingInboundState, action: PendingTagAction, ctx: LandContext) in
                    state.log.append(action.tag)
                    ctx.emitEvent(PendingActionEvent(tag: action.tag), to: .session(ctx.sessionID))
                    return PendingTagResponse(count: state.log.count)
                }
                HandleAction(PendingGatedAction.self, resolvers: PendingGateResolver.self) { (state: inout PendingInboundState, action: PendingGatedAction, _: LandContext) in
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
            playerID: "p1", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        ))
        await transport.handleIncomingMessage(sessionID: session, data: join)
        #expect(await router.isJoinPending(session), "the router returned after the admission")
        #expect(await pendingPoll { await container.keeper.currentState().log == ["joined"] }, "OnJoin ran")
    }

    func send(_ tag: String) async throws {
        await transport.handleIncomingMessage(sessionID: session, data: try actionFrame(tag))
    }

    /// A `PendingTagAction` frame (or, gated, a `PendingGatedAction` one).
    func actionFrame(_ tag: String, gated: Bool = false) throws -> Data {
        let envelope = gated
            ? ActionEnvelope(typeIdentifier: String(describing: PendingGatedAction.self), payload: AnyCodable(PendingGatedAction(tag: tag)))
            : ActionEnvelope(typeIdentifier: String(describing: PendingTagAction.self), payload: AnyCodable(PendingTagAction(tag: tag)))
        // The codec's map form: MessagePack frames on a MessagePack land, JSON on a JSON one.
        return try encoding.makeCodec().encode(TransportMessage.action(requestID: "a-\(tag)", action: envelope))
    }

    func sendGated(_ tag: String) async throws {
        await transport.handleIncomingMessage(sessionID: session, data: try actionFrame(tag, gated: true))
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
        // The entry goes in the step after the last dispatch returns, which can follow the
        // state change the log shows.
        #expect(await pendingPoll { await h.adapter.inboundAfterFlipCount(h.session) == nil }, "the drain entry is gone once empty")

        // The JoinResponse precedes every action response.
        #expect(await pendingPoll { await h.connection.messages.filter { $0.kind == .actionResponse }.count == 3 })
        // The full order on the wire: JoinResponse, then the firstSync, then the action responses.
        let frames = await h.connection.frames
        func firstIndex(_ match: (Data) -> Bool) -> Int? { frames.firstIndex(where: match) }
        let joinIndex = firstIndex { (try? JSONDecoder().decode(TransportMessage.self, from: $0))?.kind == .joinResponse }
        let firstSyncIndex = firstIndex { String(decoding: $0, as: UTF8.self).contains("firstSync") }
        let actionIndex = firstIndex { (try? JSONDecoder().decode(TransportMessage.self, from: $0))?.kind == .actionResponse }
        // OnJoin's targeted event (held until the firstSync), then the deferred actions' events.
        let joinEventIndex = firstIndex { String(decoding: $0, as: UTF8.self).contains(#""type":"PendingJoin""#) }
        let actionEventIndex = firstIndex { String(decoding: $0, as: UTF8.self).contains(#""type":"PendingAction""#) }
        #expect(joinIndex != nil && firstSyncIndex != nil && actionIndex != nil && joinEventIndex != nil && actionEventIndex != nil)
        if let joinIndex, let firstSyncIndex, let actionIndex, let joinEventIndex, let actionEventIndex {
            #expect(joinIndex < firstSyncIndex, "the JoinResponse precedes the firstSync")
            #expect(firstSyncIndex < joinEventIndex, "OnJoin's event follows the firstSync")
            #expect(joinEventIndex < actionEventIndex, "OnJoin's event precedes the deferred actions' events")
            #expect(firstSyncIndex < actionIndex, "the firstSync precedes every action response")
        }
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

    @Test("A frame right after the JoinResponse, while the router is still pending, is decoded with the negotiated MessagePack and applied at once")
    func frameAfterJoinResponseWhilePending() async throws {
        let h = try await PendingHarness.make(encoding: .messagepack)
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
        // The client stops reading once the flip's frames are out: the overflow's final frame
        // and the close then wait, and the session's membership with them.
        #expect(await pendingPoll { await h.connection.frames.contains { String(decoding: $0, as: UTF8.self).contains("firstSync") } })
        let reader = TestGate()
        await h.connection.setStall(reader)
        // "a" is being dispatched, "b" waits: one more fits, the next goes over.
        try await h.send("c")
        try await h.send("d")
        #expect(await h.adapter.inboundOverflowClosures == 1)
        #expect(await h.adapter.inboundAfterFlipCount(h.session) == nil)
        // Before the disconnect arrives a later frame still reaches the adapter: it is dropped
        // and counted, never applied.
        let droppedAtOverflow = await h.adapter.inboundDroppedForJoiningSessions
        #expect(await h.adapter.isJoined(sessionID: h.session), "the membership is still there")
        try await h.send("e")
        #expect(await h.adapter.inboundDroppedForJoiningSessions == droppedAtOverflow + 1)
        reader.open()
        await h.connection.setStall(nil)
        #expect(await pendingPoll { await h.connection.closed })
        #expect(await h.connection.errorCodes.contains(ErrorCode.inboundOverflow.rawValue))
        gate.open()
        #expect(await pendingPoll { await !h.adapter.isJoined(sessionID: h.session) })
        let log = await h.log
        #expect(!log.contains("d") && !log.contains("e"))
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
        let framesAtDisconnect = await h.connection.frames.count
        // The disconnect drops what the drain still held; the popped "a" is counted on release.
        #expect(await h.adapter.inboundDroppedForJoiningSessions == 2)
        gate.open()
        #expect(await pendingPoll { await h.adapter.inboundAfterFlipCount(h.session) == nil })
        // "a" was popped before the disconnect; "b" and "c" were not applied.
        let log = await h.log
        #expect(!log.contains("b") && !log.contains("c"))
        // The popped "a" isn't applied for a session that left, and nothing is sent after it.
        #expect(log == ["joined"])
        #expect(await pendingPoll { await h.adapter.inboundDroppedForJoiningSessions == 3 }, "the popped frame is counted too")
        #expect(await h.connection.frames.count == framesAtDisconnect, "no reply after the session ended")
    }

    @Test("A disconnect while a drained action waits in its resolver: no reply, and the rest isn't dispatched")
    func disconnectInsideDispatchedAction() async throws {
        let h = try await PendingHarness.make()
        let resolver = TestGate()
        pendingResolverGate.current = resolver
        defer { pendingResolverGate.current = nil }
        try await h.joinPending()
        try await h.sendGated("g")
        for tag in ["b", "c"] { try await h.send(tag) }
        await h.flip()
        // "g" is dispatched and suspended in its resolver; "b" and "c" wait in the drain.
        #expect(await resolver.waitForArrivals(1))
        #expect(await h.adapter.inboundAfterFlipCount(h.session) == 2)
        await h.transport.handleDisconnection(sessionID: h.session)
        #expect(await pendingPoll { await !h.adapter.isJoined(sessionID: h.session) })
        let framesAtDisconnect = await h.connection.frames.count
        #expect(await h.adapter.inboundDroppedForJoiningSessions == 2)
        resolver.open()
        #expect(await pendingPoll { await h.adapter.inboundAfterFlipCount(h.session) == nil })
        let log = await h.log
        #expect(!log.contains("b") && !log.contains("c"), "nothing more is dispatched")
        #expect(!log.contains("g"), "the suspended action isn't applied for a session that left")
        #expect(await h.connection.frames.count == framesAtDisconnect, "no reply after the session ended")
    }

    @Test("A land teardown while the drain is held: the popped frame isn't dispatched, the rest is dropped")
    func teardownDuringDrain() async throws {
        let h = try await PendingHarness.make()
        try await h.joinPending()
        for tag in ["a", "b", "c"] { try await h.send(tag) }
        let gate = TestGate()
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.inboundDrainDispatch, arrival: 1) { await gate.arrive() }.hook)
        await h.flip()
        #expect(await gate.waitForArrivals(1))
        // "a" is popped and held before its dispatch; "b" and "c" wait.
        await h.adapter.endSessionTicketsForTeardown()
        #expect(await h.adapter.inboundAfterFlipCount(h.session) == nil, "teardown clears the drain")
        #expect(await h.adapter.inboundDroppedForJoiningSessions == 2)
        gate.open()
        #expect(await pendingPoll { await h.adapter.inboundDroppedForJoiningSessions == 3 }, "the popped frame is dropped")
        #expect(await h.log == ["joined"], "nothing is dispatched after the teardown")
    }
}
