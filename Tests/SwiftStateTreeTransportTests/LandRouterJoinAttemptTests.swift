// Tests/SwiftStateTreeTransportTests/LandRouterJoinAttemptTests.swift
//
// One join attempt at a time per session (#99), and no ghost join when the session ends during
// one (#97). The router's join is held at its hold points (`afterLand`, `beforeAdmit`,
// `afterAdmit`) while the test disconnects or sends a second join, never timing. Joins are sent
// from Tasks of their own, since a held join keeps its `onMessage` call suspended.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct JoinAttemptState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [String] = []
}

/// Records each frame sent and the close.
private actor AttemptConnection: WebSocketConnection {
    private(set) var frames: [Data] = []
    private(set) var closed = false

    func send(_ data: Data) async throws { frames.append(data) }
    func close() async throws { closed = true }

    var messages: [TransportMessage] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
    }

    var errorCodes: [String] {
        messages.compactMap { if case .error(let payload) = $0.payload { return payload.code } else { return nil } }
    }

    var joinResponses: Int {
        messages.filter { $0.kind == .joinResponse }.count
    }
}

private func attemptPoll(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A router, its transport and one land.
private struct AttemptHarness {
    let transport: WebSocketTransport
    let router: LandRouter<JoinAttemptState>
    let container: LandContainer<JoinAttemptState>

    var adapter: TransportAdapter<JoinAttemptState> { container.transportAdapter }
    var keeper: LandKeeper<JoinAttemptState> { container.keeper }

    static func make() async throws -> AttemptHarness {
        let definition = Land("join-attempt", using: JoinAttemptState.self) {
            Rules {
                CanJoin { (_: JoinAttemptState, session: PlayerSession, _: LandContext) in
                    session.playerID == "deny" ? .deny(reason: "denied") : .allow(playerID: PlayerID(session.playerID))
                }
                OnJoin { (state: inout JoinAttemptState, ctx: LandContext) in
                    state.players.append(ctx.playerID.rawValue)
                }
                OnLeave { (state: inout JoinAttemptState, ctx: LandContext) in
                    state.players.removeAll { $0 == ctx.playerID.rawValue }
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in JoinAttemptState() }
        )
        let manager = LandManager<JoinAttemptState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in JoinAttemptState() },
            transport: transport
        )
        let router = LandRouter<JoinAttemptState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)
        let landID = LandID(landType: "join-attempt", instanceId: "one")
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: JoinAttemptState(), metadata: [:])
        return AttemptHarness(transport: transport, router: router, container: container)
    }

    func connect(_ session: SessionID) async -> AttemptConnection {
        let connection = AttemptConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return connection
    }

    func joinFrame(_ requestID: String, player: String) throws -> Data {
        try JSONEncoder().encode(TransportMessage.join(
            requestID: requestID, landType: "join-attempt", landInstanceId: "one",
            playerID: player, deviceID: nil, metadata: nil
        ))
    }

    /// Sends a join from a Task of its own; the task ends when the router's handler returns.
    func startJoin(_ session: SessionID, requestID: String, player: String) throws -> Task<Void, Never> {
        let frame = try joinFrame(requestID, player: player)
        let router = self.router
        return Task { await router.onMessage(frame, from: session) }
    }

    /// Holds the router once at `point`; the gate is opened by the test.
    func hold(at point: LandRouterHoldPoint) async -> TestGate {
        let gate = TestGate()
        await router.installHolds(HoldRegistry<LandRouterHoldPoint>().on(point, arrival: 1) { await gate.arrive() }.hook)
        return gate
    }

    var players: [String] {
        get async { await keeper.currentState().players }
    }
}

@Suite("LandRouter: one join attempt at a time, no ghost join (#97, #99)")
struct LandRouterJoinAttemptTests {
    @Test("A second join during the first is answered JOIN_IN_PROGRESS; the first completes alone")
    func secondJoinInProgress() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-second")
        let connection = await h.connect(session)
        let gate = await h.hold(at: .afterLand)
        let first = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        #expect(await h.router.isJoining(session))

        await h.router.onMessage(try h.joinFrame("join-2", player: "p2"), from: session)
        #expect(await attemptPoll { await connection.errorCodes == [ErrorCode.joinInProgress.rawValue] })

        gate.open()
        await first.value
        #expect(await attemptPoll { await connection.joinResponses == 1 })
        #expect(await attemptPoll { await h.players == ["p1"] }, "one keeper join, the first's")
        #expect(await h.router.getBoundLandID(for: session) == h.container.landID)
    }

    @Test("Before its admission a join keeps handshake semantics: a non-join frame is answered \"Not joined\" in JSON")
    func handshakeSemanticsBeforeAdmission() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-handshake")
        let connection = await h.connect(session)
        // Held once bound, right before the admission: the frame must still not reach the land.
        let gate = await h.hold(at: .beforeAdmit)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        let action = try JSONEncoder().encode(TransportMessage.action(
            requestID: "a-1", action: ActionEnvelope(typeIdentifier: "Anything", payload: AnyCodable([String: Int]()))
        ))
        await h.router.onMessage(action, from: session)
        #expect(await attemptPoll { await connection.errorCodes == [ErrorCode.joinSessionNotConnected.rawValue] },
                "decoded as a handshake frame and answered in JSON, straight to the transport")
        gate.open()
        await join.value
        #expect(await attemptPoll { await connection.joinResponses == 1 })
    }

    @Test("A first join that fails ends only its own attempt; a later join succeeds")
    func firstJoinFails() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-fails")
        let connection = await h.connect(session)
        let gate = await h.hold(at: .afterLand)
        let first = try h.startJoin(session, requestID: "join-1", player: "deny")
        #expect(await gate.waitForArrivals(1))
        await h.router.onMessage(try h.joinFrame("join-2", player: "p2"), from: session)
        gate.open()
        await first.value
        #expect(await attemptPoll { await connection.errorCodes == [ErrorCode.joinInProgress.rawValue, ErrorCode.joinDenied.rawValue] })
        #expect(await h.router.getBoundLandID(for: session) == nil)
        #expect(!(await h.router.isJoining(session)))

        await h.router.onMessage(try h.joinFrame("join-3", player: "p3"), from: session)
        #expect(await attemptPoll { await connection.joinResponses == 1 })
        #expect(await attemptPoll { await h.players == ["p3"] })
    }

    @Test("A disconnect during the land lookup: no binding, no phase, no player, nothing sent")
    func disconnectAfterLand() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-lookup")
        let connection = await h.connect(session)
        let gate = await h.hold(at: .afterLand)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: session)
        gate.open()
        await join.value
        #expect(await h.router.getBoundLandID(for: session) == nil, "no binding after a stale lookup")
        #expect(!(await h.router.hasHandshakePhase(session)))
        #expect(await h.players.isEmpty)
        #expect(await h.keeper.playerCount() == 0)
        #expect(await connection.frames.isEmpty, "nothing is sent to the gone session")
    }

    @Test("A server close during the land lookup: the same as a disconnect")
    func serverCloseAfterLand() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-close")
        let connection = await h.connect(session)
        let gate = await h.hold(at: .afterLand)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.closeSession(session)
        #expect(await connection.closed)
        gate.open()
        await join.value
        #expect(await h.router.getBoundLandID(for: session) == nil)
        #expect(!(await h.router.hasHandshakePhase(session)))
        #expect(await h.keeper.playerCount() == 0)
        #expect(await connection.frames.isEmpty)
    }

    @Test("A disconnect before admitJoin: the stale attempt isn't admitted")
    func disconnectBeforeAdmit() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-before-admit")
        let connection = await h.connect(session)
        let gate = await h.hold(at: .beforeAdmit)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: session)
        gate.open()
        await join.value
        #expect(await h.keeper.playerCount() == 0, "no ghost player")
        #expect(await h.players.isEmpty)
        #expect(!(await h.adapter.isJoining(session)), "never admitted")
        #expect(!(await h.router.hasHandshakePhase(session)))
        #expect(await connection.frames.isEmpty)
    }

    @Test("A stale attempt held before admitJoin doesn't supersede the player's newer connection")
    func reconnectBeforeAdmit() async throws {
        let h = try await AttemptHarness.make()
        let old = SessionID("s-old-before-admit")
        _ = await h.connect(old)
        let gate = await h.hold(at: .beforeAdmit)
        let oldJoin = try h.startJoin(old, requestID: "join-old", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: old)

        let new = SessionID("s-new-before-admit")
        let newConnection = await h.connect(new)
        await h.router.onMessage(try h.joinFrame("join-new", player: "p1"), from: new)
        #expect(await attemptPoll { await h.adapter.isJoined(sessionID: new) })

        gate.open()
        await oldJoin.value
        #expect(await h.adapter.isJoined(sessionID: new), "the newer connection is not superseded")
        #expect(!(await newConnection.closed))
        #expect(await h.router.getBoundLandID(for: new) == h.container.landID)
        #expect(await h.players == ["p1"])
        #expect(await h.keeper.playerCount() == 1)
    }

    @Test("A disconnect handled by the adapter before the admission is queued: the join undoes its own admission")
    func disconnectBeforeAdmissionQueued() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-admit-entry")
        let connection = await h.connect(session)
        // The join is past its last check, inside `admitJoin` but not yet queued.
        let admitGate = TestGate()
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.admitJoinEntry, arrival: 1) { await admitGate.arrive() }.hook)
        let forwardGate = await h.hold(at: .disconnectForwarded)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await admitGate.waitForArrivals(1))
        // The forwarded disconnect reaches the adapter first, as a no-op.
        await h.transport.handleDisconnection(sessionID: session)
        #expect(await forwardGate.waitForArrivals(1))
        forwardGate.open()
        admitGate.open()
        await join.value
        #expect(await attemptPoll { await h.keeper.playerCount() == 0 }, "no ghost player")
        #expect(await attemptPoll {
            let joined = await h.adapter.isJoined(sessionID: session)
            let joining = await h.adapter.isJoining(session)
            return !joined && !joining
        })
        #expect(await h.players.isEmpty)
        #expect(!(await h.router.hasHandshakePhase(session)))
        #expect(await connection.joinResponses == 0)
    }

    @Test("A disconnect after the admission: no phase entry, no JoinResponse, the player removed")
    func disconnectAfterAdmit() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-after-admit")
        let connection = await h.connect(session)
        let gate = await h.hold(at: .afterAdmit)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        // In-turn, the flip may already have sent the JoinResponse: the admission is done.
        await h.transport.handleDisconnection(sessionID: session)
        let framesAtDisconnect = await connection.frames.count
        gate.open()
        await join.value
        #expect(!(await h.router.hasHandshakePhase(session)), "the stale attempt re-adds no phase entry")
        #expect(await h.router.getBoundLandID(for: session) == nil)
        #expect(await attemptPoll { await h.keeper.playerCount() == 0 })
        #expect(await attemptPoll {
            let joined = await h.adapter.isJoined(sessionID: session)
            let joining = await h.adapter.isJoining(session)
            return !joined && !joining
        })
        // Nothing is written after the disconnect; off path, the stale attempt sends no
        // JoinResponse and sets no `.joined`.
        #expect(await connection.frames.count == framesAtDisconnect)
        #expect(!(await h.router.hasHandshakePhase(session)), "nothing re-added it since")
    }

    @Test("A reconnect with a new SessionID while the old join is held: each touches only its own session")
    func reconnectWithNewID() async throws {
        let h = try await AttemptHarness.make()
        let old = SessionID("s-old")
        let oldConnection = await h.connect(old)
        let gate = await h.hold(at: .afterAdmit)
        let oldJoin = try h.startJoin(old, requestID: "join-old", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: old)
        let oldFramesAtDisconnect = await oldConnection.frames.count

        let new = SessionID("s-new")
        let newConnection = await h.connect(new)
        await h.router.onMessage(try h.joinFrame("join-new", player: "p1"), from: new)
        #expect(await attemptPoll { await newConnection.joinResponses == 1 })
        #expect(await newConnection.errorCodes.isEmpty, "not JOIN_IN_PROGRESS")

        gate.open()
        await oldJoin.value
        #expect(await h.router.getBoundLandID(for: new) == h.container.landID, "the new binding survives")
        #expect(await attemptPoll { await h.adapter.isJoined(sessionID: new) })
        #expect(await h.players == ["p1"])
        #expect(!(await h.router.hasHandshakePhase(old)))
        #expect(await oldConnection.frames.count == oldFramesAtDisconnect, "the old join writes nothing")
    }

    @Test(
        "Off path, a disconnect while the JoinResponse is sent: no `.joined`, no initial sync",
        .enabled(if: !InTurnSync.isEnabled(), "IN_TURN_SYNC=true: the router sends no JoinResponse")
    )
    func disconnectWhileJoinResponseSent() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-response")
        let connection = await h.connect(session)
        let gate = await h.hold(at: .joinResponseSent)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: session)
        let framesAtDisconnect = await connection.frames.count
        gate.open()
        await join.value
        #expect(!(await h.router.hasHandshakePhase(session)), "the stale attempt sets no `.joined`")
        #expect(await connection.frames.count == framesAtDisconnect, "no initial sync to the gone session")
        #expect(await attemptPoll { await h.keeper.playerCount() == 0 })
    }
}
