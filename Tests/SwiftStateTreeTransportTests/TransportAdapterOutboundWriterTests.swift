// Tests/SwiftStateTreeTransportTests/TransportAdapterOutboundWriterTests.swift
//
// The adapter's outbound writer (#60): one FIFO per adapter for every frame sent to a session of
// its land after it joins. Covers join order through `LandRouter`, connection generations on
// reconnect, the backlog counter and ceiling, teardown, and the writer's lifetime.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Shared pieces

@StateNodeBuilder
struct WriterTestState: StateNodeProtocol {
    @Sync(.broadcast) var stamp: String = "mk-000000"
    init() {}
}

@Payload
struct WriterSetAction: ActionPayload {
    typealias Response = WriterSetResponse
    let stamp: Int
}

@Payload
struct WriterSetResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct WriterEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

private func writerMarker(_ n: Int) -> String {
    "mk-" + String(format: "%06d", n)
}

private func writerLand(_ id: String) -> LandDefinition<WriterTestState> {
    Land(id, using: WriterTestState.self) {
        ServerEvents { Register(WriterEvent.self) }
        Rules {
            HandleAction(WriterSetAction.self) { (state: inout WriterTestState, action: WriterSetAction, _: LandContext) in
                state.stamp = writerMarker(action.stamp)
                return WriterSetResponse(ok: true)
            }
        }
    }
}

private actor WriterConnection: WebSocketConnection {
    private var frames: [Data] = []
    func send(_ data: Data) async throws { frames.append(data) }
    func close() async throws {}
    func recorded() -> [Data] { frames }
}

private func contains(_ frame: Data, _ text: String) -> Bool {
    frame.range(of: Data(text.utf8)) != nil
}

private func waitForFrames(
    _ connection: WriterConnection,
    _ what: String,
    timeout: Duration = .seconds(3),
    _ condition: ([Data]) -> Bool
) async throws -> [Data] {
    let deadline = ContinuousClock.now + timeout
    while true {
        let frames = await connection.recorded()
        if condition(frames) { return frames }
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what); frames: \(frames.map { String(decoding: $0, as: UTF8.self).prefix(80) })")
            return frames
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private func writerEnvConfig(outboundWriterMaxBytes: Int = TransportEnvConfig.defaultOutboundWriterMaxBytes) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: true,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: false,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: nil,
        outboundWriterMaxBytes: outboundWriterMaxBytes
    )
}

// MARK: - Tests

@Suite("TransportAdapter outbound writer (#60)", .timeLimit(.minutes(1)))
struct TransportAdapterOutboundWriterTests {

    @Test("join through LandRouter: join response, then firstSync, then the first diff")
    func joinResponseFirstSyncThenDiff() async throws {
        let transport = WebSocketTransport()
        let registry = LandTypeRegistry<WriterTestState>(
            landFactory: { _, _ in writerLand("writer-join") },
            initialStateFactory: { _, _ in WriterTestState() }
        )
        let landManager = LandManager<WriterTestState>(
            landFactory: { landID in registry.getLandDefinition(landType: landID.landType, landID: landID) },
            initialStateFactory: { landID in registry.initialStateFactory(landID.landType, landID) },
            transport: transport
        )
        let router = LandRouter<WriterTestState>(
            landManager: landManager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)

        let session = SessionID("wr-join-session")
        let connection = WriterConnection()
        await transport.handleConnection(sessionID: session, connection: connection)
        let join = TransportMessage.join(
            requestID: "wr-join-1",
            landType: "writer-join",
            landInstanceId: nil,
            playerID: "wr-join-player",
            deviceID: "wr-dev",
            metadata: nil
        )
        await transport.handleIncomingMessage(sessionID: session, data: try JSONEncoder().encode(join))
        _ = try await waitForFrames(connection, "join response and firstSync") { $0.count >= 2 }

        guard let landID = await router.getBoundLandID(for: session),
              let container = await landManager.getLand(landID: landID) else {
            Issue.record("session not bound to a land")
            return
        }
        // Sent by the client on its connection (the keeper only takes inputs from the player's
        // current client and session).
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: WriterSetAction.self),
            payload: AnyCodable(WriterSetAction(stamp: 7))
        )
        let action = TransportMessage.action(requestID: "wr-join-action", action: envelope)
        await transport.handleIncomingMessage(sessionID: session, data: try JSONEncoder().encode(action))
        _ = try await waitForFrames(connection, "the action response") { frames in
            frames.contains { contains($0, "wr-join-action") }
        }
        await container.transportAdapter.syncNow()
        let frames = try await waitForFrames(connection, "the first diff") { frames in
            frames.contains { contains($0, writerMarker(7)) }
        }

        let joinIndex = frames.firstIndex { contains($0, "joinResponse") }
        let firstSyncIndex = frames.firstIndex { contains($0, writerMarker(0)) }
        let diffIndex = frames.firstIndex { contains($0, writerMarker(7)) }
        #expect(joinIndex != nil && firstSyncIndex != nil && diffIndex != nil)
        if let j = joinIndex, let s = firstSyncIndex, let d = diffIndex {
            #expect(j < s, "join response (\(j)) before firstSync (\(s))")
            #expect(s < d, "firstSync (\(s)) before the first diff (\(d))")
        }
    }

    @Test("reconnect with the same SessionID: frames for the old connection do not reach the new one")
    func oldGenerationFramesAreDropped() async throws {
        let transport = WebSocketTransport()
        let keeper = LandKeeper<WriterTestState>(definition: writerLand("writer-gen"), initialState: WriterTestState())
        let adapter = TransportAdapter<WriterTestState>(
            keeper: keeper,
            transport: transport,
            landID: "writer-gen",
            transportEnvConfig: writerEnvConfig(),
            encodingConfig: .json
        )
        let session = SessionID("wr-gen-session")
        let client = ClientID("wr-gen-client")
        let old = WriterConnection()
        await transport.handleConnection(sessionID: session, connection: old)
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper,
            sessionID: session, clientID: client, playerID: PlayerID("wr-gen-player")
        )
        _ = try await waitForFrames(old, "firstSync on the old connection") { !$0.isEmpty }

        // A new connection reuses the SessionID before the adapter hears about it.
        await transport.handleDisconnection(sessionID: session)
        let fresh = WriterConnection()
        await transport.handleConnection(sessionID: session, connection: fresh)

        await adapter.sendEvent(AnyServerEvent(WriterEvent(message: "wr-old-generation")), to: .all)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: WriterSetAction.self),
            payload: AnyCodable(WriterSetAction(stamp: 3))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope, playerID: PlayerID("wr-gen-player"), clientID: client, sessionID: session
        )
        await adapter.syncNow()
        try await Task.sleep(for: .milliseconds(100))

        let leaked = await fresh.recorded()
        #expect(leaked.isEmpty, "the new connection must not get the old connection's frames; got \(leaked.count)")
    }

    @Test("after a disconnect, late frames for the session are dropped, also without a generation; a rejoin sends again")
    func lateFramesForEndedSessionAreDropped() async throws {
        // No generations: BlockingTransport is not a WebSocketTransport.
        let transport = BlockingTransport()
        let keeper = LandKeeper<WriterTestState>(definition: writerLand("writer-ended"), initialState: WriterTestState())
        let adapter = TransportAdapter<WriterTestState>(
            keeper: keeper,
            transport: transport,
            landID: "writer-ended",
            transportEnvConfig: writerEnvConfig(),
            encodingConfig: .json
        )
        await transport.setDelegate(adapter)
        let session = SessionID("wr-ended-session")
        let client = ClientID("wr-ended-client")
        let player = PlayerID("wr-ended-player")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
        try await waitUntilTransportIdle(transport)

        await adapter.onDisconnect(sessionID: session, clientID: client)
        // A late frame for the ended connection, e.g. an action response still in flight.
        await adapter.enqueueOutbound(Data("wr-late-frame".utf8), to: session)
        #expect(await adapter.waitForOutboundDrain())
        #expect(!transport.frames(for: session).contains { contains($0, "wr-late-frame") }, "late frame for an ended session must be dropped")

        // A new connection under the same SessionID joins: frames flow again.
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
        await adapter.enqueueOutbound(Data("wr-after-rejoin".utf8), to: session)
        #expect(await adapter.waitForOutboundDrain())
        #expect(transport.frames(for: session).contains { contains($0, "wr-after-rejoin") })
    }

    @Test("ceiling: a dropped element disconnects the sessions it addressed; others are unaffected; no later frame reaches them")
    func ceilingDropDisconnectsAddressedSessions() async throws {
        let transport = BlockingTransport()
        let keeper = LandKeeper<WriterTestState>(definition: writerLand("writer-ceiling"), initialState: WriterTestState())
        let adapter = TransportAdapter<WriterTestState>(
            keeper: keeper,
            transport: transport,
            landID: "writer-ceiling",
            transportEnvConfig: writerEnvConfig(outboundWriterMaxBytes: 4096),
            encodingConfig: .json
        )
        await transport.setDelegate(adapter)
        let sessionA = SessionID("wr-ceiling-a")
        let sessionB = SessionID("wr-ceiling-b")
        let playerA = PlayerID("wr-ceiling-player-a")
        let playerB = PlayerID("wr-ceiling-player-b")
        for (session, player) in [(sessionA, playerA), (sessionB, playerB)] {
            let client = ClientID("client-\(session.rawValue)")
            await adapter.onConnect(sessionID: session, clientID: client)
            try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
        }
        try await waitUntilTransportIdle(transport)

        transport.block()
        // A's events only: the first element blocks in the transport, the rest wait in the writer
        // until the ceiling drops one.
        for n in 0..<200 {
            await adapter.sendEvent(AnyServerEvent(WriterEvent(message: "wr-fill-\(n)")), to: .player(playerA))
        }
        let backlog = await adapter.outboundBacklog()
        #expect(backlog.elements > 0 && backlog.bytes > 0, "backlog while blocked: \(backlog)")
        #expect(backlog.bytes <= 4096, "the ceiling bounds the queued bytes: \(backlog)")
        #expect(backlog.dropped > 0, "elements over the ceiling are dropped and counted: \(backlog)")
        #expect(await adapter.outboundCeilingDisconnectCount() == 1, "one session addressed by the dropped elements")

        transport.release()
        #expect(await adapter.waitForOutboundDrain())
        try await orderedWaitUntil("A to be closed") { transport.closedSessions.contains(sessionA) }
        #expect(transport.closedSessions == [sessionA], "only the addressed session is closed: \(transport.closedSessions)")

        // Kept frames stay in issue order; nothing after the drop reaches A.
        let delivered = transport.frames(for: sessionA)
            .map { String(decoding: $0, as: UTF8.self) }
            .compactMap { text -> Int? in
                guard let range = text.range(of: "wr-fill-") else { return nil }
                return Int(text[range.upperBound...].prefix { $0.isNumber })
            }
        #expect(delivered == delivered.sorted(), "kept frames stay in issue order")
        #expect(delivered.first == 0, "the first frame was not dropped")

        let aBefore = transport.frames(for: sessionA).count
        await adapter.sendEvent(AnyServerEvent(WriterEvent(message: "wr-after-drop")), to: .all)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: WriterSetAction.self),
            payload: AnyCodable(WriterSetAction(stamp: 9))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope, playerID: playerB, clientID: ClientID("client-\(sessionB.rawValue)"), sessionID: sessionB
        )
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain())
        try await orderedWaitUntil("B to get the later frames") {
            transport.frames(for: sessionB).contains { contains($0, writerMarker(9)) }
        }
        #expect(transport.frames(for: sessionA).count == aBefore, "no frame reaches A after its disconnect")
        #expect(transport.frames(for: sessionB).contains { contains($0, "wr-after-drop") }, "B is unaffected")
    }

    @Test("teardown drains queued frames; frames enqueued after it are not sent")
    func teardownDrainsQueuedFrames() async throws {
        let transport = BlockingTransport()
        let keeper = LandKeeper<WriterTestState>(definition: writerLand("writer-teardown"), initialState: WriterTestState())
        let adapter = TransportAdapter<WriterTestState>(
            keeper: keeper,
            transport: transport,
            landID: "writer-teardown",
            transportEnvConfig: writerEnvConfig(),
            encodingConfig: .json
        )
        await transport.setDelegate(adapter)
        let session = SessionID("wr-teardown-session")
        let client = ClientID("wr-teardown-client")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper,
            sessionID: session, clientID: client, playerID: PlayerID("wr-teardown-player")
        )
        try await waitUntilTransportIdle(transport)

        transport.block()
        for n in 0..<5 {
            await adapter.sendEvent(AnyServerEvent(WriterEvent(message: "wr-queued-\(n)")), to: .all)
        }
        let teardown = Task { await adapter.onLandDestroyed() }
        try await Task.sleep(for: .milliseconds(20))
        transport.release()
        await teardown.value

        let frames = transport.frames(for: session).map { String(decoding: $0, as: UTF8.self) }
        for n in 0..<5 {
            #expect(frames.filter { $0.contains("wr-queued-\(n)") }.count == 1, "wr-queued-\(n) delivered once")
        }
        await adapter.sendEvent(AnyServerEvent(WriterEvent(message: "wr-after-teardown")), to: .all)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!transport.frames(for: session).contains { contains($0, "wr-after-teardown") })
    }

    @Test("teardown is bounded: onLandDestroyed returns within the deadline when the transport never returns")
    func teardownIsBoundedWhenTransportNeverReturns() async throws {
        let transport = BlockingTransport()
        let keeper = LandKeeper<WriterTestState>(definition: writerLand("writer-stuck"), initialState: WriterTestState())
        let destroyed = OrderedSendFlag()
        let adapter = TransportAdapter<WriterTestState>(
            keeper: keeper,
            transport: transport,
            landID: "writer-stuck",
            onLandDestroyed: { destroyed.set() },
            transportEnvConfig: writerEnvConfig(),
            encodingConfig: .json
        )
        await transport.setDelegate(adapter)
        let session = SessionID("wr-stuck-session")
        let client = ClientID("wr-stuck-client")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper,
            sessionID: session, clientID: client, playerID: PlayerID("wr-stuck-player")
        )
        try await waitUntilTransportIdle(transport)

        transport.block()  // not released before teardown returns
        await adapter.sendEvent(AnyServerEvent(WriterEvent(message: "wr-stuck")), to: .all)
        let start = ContinuousClock.now
        await adapter.onLandDestroyed()
        let elapsed = ContinuousClock.now - start
        #expect(destroyed.isSet, "the destroy callback runs although the transport never returned")
        #expect(elapsed < TransportAdapter<WriterTestState>.outboundTeardownTimeout + .seconds(1), "teardown took \(elapsed)")
        transport.release()
    }

    @Test("the writer's consumer does not keep the adapter alive")
    func consumerDoesNotRetainAdapter() async throws {
        let transport = WebSocketTransport()
        weak var weakAdapter: TransportAdapter<WriterTestState>?
        do {
            let keeper = LandKeeper<WriterTestState>(definition: writerLand("writer-lifetime"), initialState: WriterTestState())
            let adapter = TransportAdapter<WriterTestState>(
                keeper: keeper,
                transport: transport,
                landID: "writer-lifetime",
                transportEnvConfig: writerEnvConfig(),
                encodingConfig: .json
            )
            let session = SessionID("wr-lifetime-session")
            let client = ClientID("wr-lifetime-client")
            await transport.handleConnection(sessionID: session, connection: WriterConnection())
            await adapter.onConnect(sessionID: session, clientID: client)
            try await simulateRouterJoin(
                adapter: adapter, keeper: keeper,
                sessionID: session, clientID: client, playerID: PlayerID("wr-lifetime-player")
            )
            await adapter.sendEvent(AnyServerEvent(WriterEvent(message: "wr-lifetime")), to: .all)
            weakAdapter = adapter
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while weakAdapter != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(weakAdapter == nil, "the adapter must be released once its owner drops it")
    }
}
