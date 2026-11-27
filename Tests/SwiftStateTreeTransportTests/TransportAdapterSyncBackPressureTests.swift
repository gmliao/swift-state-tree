// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncBackPressureTests.swift
//
// Sync back-pressure: while the adapter's outbound writer still holds a sync cycle element from
// an earlier cycle, a new sync phase is deferred before it plans (dirty flags and
// queued events stay), and runs again once the writer drained. A joiner's firstSync, the debug settle
// and action responses are not held back.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct BackPressureState: StateNodeProtocol {
    @Sync(.broadcast) var stamp: String = "bp-000000"
    init() {}
}

@Payload
struct BackPressureSetAction: ActionPayload {
    typealias Response = BackPressureSetResponse
    let stamp: Int
}

@Payload
struct BackPressureSetResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct BackPressureEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

private func bpMarker(_ n: Int) -> String {
    "bp-" + String(format: "%06d", n)
}

/// Tickless (no periodic sync): a skipped cycle is run again once the writer drained.
private func bpLand(_ id: String) -> LandDefinition<BackPressureState> {
    Land(id, using: BackPressureState.self) {
        ServerEvents { Register(BackPressureEvent.self) }
        Rules {
            HandleAction(BackPressureSetAction.self) { state, action, ctx in
                state.stamp = bpMarker(action.stamp)
                // Tickless: the action asks for a sync (runs only when the keeper has a transport).
                ctx.requestSyncNow()
                return BackPressureSetResponse(ok: true)
            }
        }
    }
}

private func bpEnvConfig() -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: true,
        syncStrategy: .delta,
        profilingConfig: nil
    )
}

private func has(_ frames: [Data], _ text: String) -> Int {
    frames.filter { $0.range(of: Data(text.utf8)) != nil }.count
}

private struct BPFixture {
    let keeper: LandKeeper<BackPressureState>
    let adapter: TransportAdapter<BackPressureState>
    let transport: BlockingTransport
    let session: SessionID
    let client: ClientID
    let player: PlayerID

    /// The backlog retry is the keeper's writer-drain retry.
    static func make(_ id: String, encoding: TransportEncodingConfig, keeperDrivesSync: Bool = false) async throws -> BPFixture {
        let transport = BlockingTransport()
        let keeper = LandKeeper<BackPressureState>(definition: bpLand(id), initialState: BackPressureState())
        let adapter = TransportAdapter<BackPressureState>(
            keeper: keeper,
            transport: transport,
            landID: id,
            transportEnvConfig: bpEnvConfig(),
            encodingConfig: encoding
        )
        if keeperDrivesSync { await keeper.setTransport(adapter) }
        await transport.setDelegate(adapter)
        let session = SessionID("\(id)-session")
        let client = ClientID("\(id)-client")
        let player = PlayerID("\(id)-player")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
        try await waitUntilTransportIdle(transport)
        return BPFixture(keeper: keeper, adapter: adapter, transport: transport, session: session, client: client, player: player)
    }

    func set(_ stamp: Int) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: BackPressureSetAction.self),
            payload: AnyCodable(BackPressureSetAction(stamp: stamp))
        )
        _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
    }

    /// Blocks the transport and runs one cycle whose element then stays in the writer.
    func blockWithCycleInWriter(stamp: Int) async throws {
        transport.block()
        try await set(stamp)
        await adapter.syncNow()
        #expect(await adapter.outboundBacklog().syncCycleElements == 1, "the cycle's element waits in the writer")
    }
}

@Suite("TransportAdapter sync back-pressure", .timeLimit(.minutes(1)))
struct TransportAdapterSyncBackPressureTests {
    @Test("a cycle is skipped while an earlier cycle's element is in the writer; flags and events are kept and delivered after the drain")
    func skipsWhileWriterHoldsCycleAndDeliversAfterDrain() async throws {
        let f = try await BPFixture.make("bp-skip", encoding: .messagepack)
        try await f.blockWithCycleInWriter(stamp: 1)

        try await f.set(2)
        await f.adapter.sendEvent(AnyServerEvent(BackPressureEvent(message: "bp-kept-broadcast")), to: .all)
        await f.adapter.sendEvent(AnyServerEvent(BackPressureEvent(message: "bp-kept-targeted")), to: .player(f.player))
        let skippedBefore = await f.adapter.syncSkipCounts().outboundBacklog
        await f.adapter.syncNow()
        await f.adapter.syncNow()
        #expect(await f.adapter.syncSkipCounts().outboundBacklog == skippedBefore + 2, "syncNow and broadcast-only are skipped")
        #expect(await f.adapter.outboundBacklog().syncCycleElements == 1, "a skipped cycle enqueues nothing")
        let pending = await f.adapter.pendingEventCounts()
        #expect(pending.broadcast == 1 && pending.targeted == 1, "queued events stay for the next cycle: \(pending)")
        #expect(has(f.transport.frames(for: f.session), bpMarker(2)) == 0, "stamp 2 is not sent while skipped")

        // The land has no periodic sync: the skipped cycle runs once the writer drained.
        f.transport.release()
        try await orderedWaitUntil("the deferred cycle to deliver stamp 2 and the events") {
            let frames = f.transport.frames(for: f.session)
            return has(frames, bpMarker(2)) > 0 && has(frames, "bp-kept-broadcast") > 0 && has(frames, "bp-kept-targeted") > 0
        }
        #expect(await f.adapter.waitForOutboundDrain())
        let frames = f.transport.frames(for: f.session)
        #expect(has(frames, bpMarker(1)) >= 1)
        #expect(has(frames, "bp-kept-broadcast") == 1, "the broadcast event is delivered once")
        #expect(has(frames, "bp-kept-targeted") == 1, "the targeted event is delivered once")
        #expect(await f.adapter.pendingEventCounts() == (0, 0))

        // Client == server: the next cycle has nothing left to send (the stamp 2 diff went out).
        let before = f.transport.frames(for: f.session).count
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(f.transport.frames(for: f.session).count == before, "no diff left after the deferred cycle")
        #expect(await f.keeper.currentState().stamp == bpMarker(2))
    }

    @Test("event and response elements in the writer never hold back a state cycle")
    func eventBacklogDoesNotSuppressStateSyncs() async throws {
        let f = try await BPFixture.make("bp-events", encoding: .json)
        // json sends events when emitted: each is its own (non-state) writer element.
        f.transport.block()
        for n in 0..<50 {
            await f.adapter.sendEvent(AnyServerEvent(BackPressureEvent(message: "bp-ev-\(n)")), to: .all)
        }
        #expect(await f.adapter.outboundBacklog().elements > 1)
        #expect(await f.adapter.hasPendingStateElement == false, "only event elements are queued")
        try await f.set(1)
        let skipsBefore = await f.adapter.syncSkipCounts()
        await f.adapter.syncNow()
        #expect(await f.adapter.syncSkipCounts() == skipsBefore, "the state cycle is not skipped")
        #expect(await f.adapter.hasPendingStateElement, "the cycle's element is queued behind the events")
        f.transport.release()
        #expect(await f.adapter.waitForOutboundDrain())

        // A land that emits an event with every state change still gets every state cycle.
        for n in 2...21 {
            await f.adapter.sendEvent(AnyServerEvent(BackPressureEvent(message: "bp-tick-ev-\(n)")), to: .all)
            try await f.set(n)
            await f.adapter.syncNow()
            #expect(await f.adapter.waitForOutboundDrain())
        }
        #expect(await f.adapter.syncSkipCounts() == skipsBefore)
        let frames = f.transport.frames(for: f.session)
        for n in 1...21 {
            #expect(has(frames, bpMarker(n)) >= 1, "stamp \(n) delivered")
        }
    }

    @Test("a joiner's firstSync is not skipped while the writer holds a cycle")
    func firstSyncIsNotSkipped() async throws {
        let f = try await BPFixture.make("bp-join", encoding: .json)
        try await f.blockWithCycleInWriter(stamp: 1)

        let sessionB = SessionID("bp-join-session-b")
        let clientB = ClientID("bp-join-client-b")
        let playerB = PlayerID("bp-join-player-b")
        await f.adapter.onConnect(sessionID: sessionB, clientID: clientB)
        let decision = try await f.keeper.join(
            session: PlayerSession(playerID: playerB.rawValue, deviceID: "dev-b", metadata: [:]),
            clientID: clientB,
            sessionID: sessionB,
            services: LandServices()
        )
        guard case .allow(let joined) = decision else { Issue.record("join denied"); return }
        await f.adapter.registerSession(sessionID: sessionB, clientID: clientB, playerID: joined, authInfo: nil)
        _ = await f.adapter.allocatePlayerSlot(accountKey: joined.rawValue, for: joined)
        let skippedBefore = await f.adapter.syncSkipCounts().outboundBacklog
        await f.adapter.syncStateForNewPlayer(playerID: joined, sessionID: sessionB)
        #expect(await f.adapter.syncSkipCounts().outboundBacklog == skippedBefore, "firstSync is not a skipped cycle")

        f.transport.release()
        try await orderedWaitUntil("B's firstSync with the current stamp") {
            has(f.transport.frames(for: sessionB), bpMarker(1)) > 0
        }
        #expect(await f.adapter.waitForOutboundDrain())
    }

    @Test("the debug settle is not skipped: it waits for the writer to drain, then syncs")
    func settleWaitsForDrain() async throws {
        let f = try await BPFixture.make("bp-settle", encoding: .json)
        // The settle runs only through the keeper's attached transport (#546 L2d-1).
        await f.keeper.setTransport(f.adapter)
        try await f.blockWithCycleInWriter(stamp: 1)
        try await f.set(2)
        // The settle waits behind the held writer: no deadline may fire inside the hold (#928).
        await f.adapter.setDebugFreezeSettleDeadline(freezeWithoutDeadline)
        await f.adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
        let registered = TestGate()
        registered.open()
        let writer = await f.adapter.outboundWriter
        writer.setOnSyncCycleDrainWaitRegisteredForTesting { Task { await registered.arrive() } }
        defer { writer.setOnSyncCycleDrainWaitRegisteredForTesting(nil) }

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try #require(await registered.waitForArrivals(1), "the settle never waited for the writer")
        #expect(has(f.transport.frames(for: f.session), bpMarker(2)) == 0, "the settle waits behind the queued cycle")
        let skippedBefore = await f.adapter.syncSkipCounts().outboundBacklog

        f.transport.release()
        let response = try await freeze.value
        #expect(await f.adapter.syncSkipCounts().outboundBacklog == skippedBefore, "the settle is not counted as skipped")
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(has(f.transport.frames(for: f.session), bpMarker(2)) > 0, "the settle cycle delivered stamp 2")
        #expect(await f.adapter.debugResume(freezeToken: response.freezeToken).resumed)
    }

    @Test("the debug settle behind a writer that never drains times out at its deadline and leaves no wait behind")
    func settleTimesOutBehindAStuckWriter() async throws {
        let f = try await BPFixture.make("bp-settle-stuck", encoding: .json)
        // The settle runs only through the keeper's attached transport (#546 L2d-1).
        await f.keeper.setTransport(f.adapter)
        defer { f.transport.release() }
        try await f.blockWithCycleInWriter(stamp: 1)
        try await f.set(2)
        // The settle's own deadline is what ends the wait; the writer never drains before it.
        await f.adapter.setDebugFreezeSettleDeadline(.milliseconds(100))

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        // When the hang bound runs out first, releasing the transport drains the writer, so a
        // wait the deadline couldn't end returns and the test fails by name instead of hanging.
        let outcome = await withTaskGroup(of: Result<DebugFreezeResponse, any Error>?.self) { group in
            group.addTask { await freeze.result }
            group.addTask {
                try? await safeTaskSleep(for: testHangBound)
                f.transport.release()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let result = try #require(outcome, "the settle didn't end at its deadline")
        #expect(throws: DebugFreezeError.settleTimedOut) { try result.get() }
        #expect(await f.adapter.outboundWriter.syncCycleDrainWaitEntriesForTesting == 0, "the timed-out wait left its waiter")
        #expect(await f.adapter.isDebugFrozen() == false, "the timed-out freeze was released")
    }

    @Test("a release ends a debug settle waiting behind a writer that never drains: released, at once, and no wait is left behind")
    func releaseEndsTheSettlesWriterWait() async throws {
        let f = try await BPFixture.make("bp-settle-released", encoding: .json)
        // The settle runs only through the keeper's attached transport (#546 L2d-1).
        await f.keeper.setTransport(f.adapter)
        defer { f.transport.release() }
        try await f.blockWithCycleInWriter(stamp: 1)
        try await f.set(2)
        // Far past the hang bound: only the release can end the wait in time.
        await f.adapter.setDebugFreezeSettleDeadline(.seconds(3600))
        await f.adapter.setDebugFreezeAutoResumeTimeout(.seconds(3600))
        let registered = TestGate()
        registered.open()
        let writer = await f.adapter.outboundWriter
        writer.setOnSyncCycleDrainWaitRegisteredForTesting { Task { await registered.arrive() } }
        defer { writer.setOnSyncCycleDrainWaitRegisteredForTesting(nil) }

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try #require(await registered.waitForArrivals(1), "the settle never waited for the writer")
        let token = await f.adapter.debugFreezeState.token
        #expect(await f.adapter.debugResume(freezeToken: token).resumed)

        // When the hang bound runs out first, releasing the transport drains the writer, so a
        // wait the release couldn't end returns and the test fails by name instead of hanging.
        let outcome = await withTaskGroup(of: Result<DebugFreezeResponse, any Error>?.self) { group in
            group.addTask { await freeze.result }
            group.addTask {
                try? await safeTaskSleep(for: testHangBound)
                f.transport.release()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let result = try #require(outcome, "the released settle kept waiting for the writer")
        #expect(throws: DebugFreezeError.released) { try result.get() }
        #expect(writer.syncCycleDrainWaitEntriesForTesting == 0, "the cancelled wait left its waiter")
        #expect(await f.adapter.isDebugFrozen() == false)
    }

    @Test("tickless land: an action during the backlog gets its response, and its state reaches the client")
    func actionDuringBacklogGetsResponse() async throws {
        let f = try await BPFixture.make("bp-action", encoding: .json, keeperDrivesSync: true)
        f.transport.block()
        try await f.set(1)  // the action requests syncNow: its cycle's element blocks the writer
        try await orderedWaitUntil("the first cycle to be in the writer") {
            has(f.transport.frames(for: f.session), bpMarker(1)) > 0
        }

        let request = TransportMessage.action(
            requestID: "bp-action-req",
            action: ActionEnvelope(
                typeIdentifier: String(describing: BackPressureSetAction.self),
                payload: AnyCodable(BackPressureSetAction(stamp: 2))
            )
        )
        await f.adapter.onMessage(try JSONEncoder().encode(request), from: f.session)
        #expect(await f.adapter.syncSkipCounts().outboundBacklog >= 1, "the action's sync cycle was skipped")

        f.transport.release()
        try await orderedWaitUntil("the action response and stamp 2") {
            let frames = f.transport.frames(for: f.session)
            return has(frames, "bp-action-req") > 0 && has(frames, bpMarker(2)) > 0
        }
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(has(f.transport.frames(for: f.session), "bp-action-req") == 1, "one response")
    }
}
