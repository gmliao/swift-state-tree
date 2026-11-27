// Tests/SwiftStateTreeTransportTests/LandRouterJoinAttemptTests.swift
//
// One join attempt at a time per session (#99), and no ghost join when the session ends during
// one (#97). The router's join is held at its hold points (`afterLand`, `beforeAdmit`,
// `afterAdmit`) while the test disconnects or sends a second join, never timing. Joins are sent
// from Tasks of their own, since a held join keeps its `onMessage` call suspended.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct JoinAttemptState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [String] = []
    /// OnLeave runs: a kick of a player's session by its newer join runs one.
    @Sync(.broadcast)
    var leaves: Int = 0
}

/// Records each frame sent and the close.
private actor AttemptConnection: WebSocketConnection {
    private struct FrameWaiter {
        let condition: @Sendable ([TransportMessage]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var frames: [Data] = []
    private(set) var closed = false
    /// Close codes, in order: 1000 for a plain `close()`.
    private(set) var closeCodes: [UInt16] = []
    private(set) var sendAttempts = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Arrives once per send attempt, before the hold (`holdSends`); open, so a send never
    /// waits on it.
    let attempted: TestGate = {
        let gate = TestGate()
        gate.open()
        return gate
    }()
    /// Arrives once per close; open, so a close never waits on it (`waitUntilClosed`).
    private let closeSignal: TestGate = {
        let gate = TestGate()
        gate.open()
        return gate
    }()
    private var frameWaiters: [Int: FrameWaiter] = [:]
    private var nextWaiterID = 0

    /// Holds every send from now on, until `releaseSends`.
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
        frames.append(data)
        let sent = messages
        for (id, waiter) in frameWaiters where waiter.condition(sent) {
            frameWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: true)
        }
    }

    func close() async throws { await recordClose(1000) }
    func close(with close: SessionClose) async throws { await recordClose(close.code) }

    private func recordClose(_ code: UInt16) async {
        closed = true
        closeCodes.append(code)
        await closeSignal.arrive()
    }

    /// Waits for the connection's close, on the event, not by polling. `false` after the
    /// gate's hang bound.
    func waitUntilClosed() async -> Bool {
        await closeSignal.waitForArrivals(1)
    }

    var messages: [TransportMessage] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
    }

    /// Waits until the messages sent so far meet `condition`; resumed by `send`, not by
    /// polling. `false` after `testHangBound` (a hang guard), when the frame never comes.
    func waitUntilMessages(_ condition: @escaping @Sendable ([TransportMessage]) -> Bool) async -> Bool {
        if condition(messages) { return true }
        let id = nextWaiterID
        nextWaiterID += 1
        let hangGuard = Task { [weak self] in
            try? await safeTaskSleep(for: testHangBound)
            await self?.expireWaiter(id)
        }
        defer { hangGuard.cancel() }
        return await withCheckedContinuation { continuation in
            frameWaiters[id] = FrameWaiter(condition: condition, continuation: continuation)
        }
    }

    /// Waits for the join's JoinResponse: the router sends it once the join is admitted.
    func waitForJoinResponse() async -> Bool {
        await waitUntilMessages { $0.contains { $0.kind == .joinResponse } }
    }

    /// Waits until the error codes sent are exactly `codes`.
    func waitForErrorCodes(_ codes: [String]) async -> Bool {
        await waitUntilMessages { messages in
            messages.compactMap { if case .error(let payload) = $0.payload { return payload.code } else { return nil } } == codes
        }
    }

    private func expireWaiter(_ id: Int) {
        frameWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
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
                CanJoin { _, session, _ in
                    if session.playerID == "deny" { return .deny(reason: "denied") }
                    // A mapped player (#234): "alias-<p>" joins as <p>.
                    let requested = session.playerID
                    let prefix = "alias-"
                    return .allow(playerID: PlayerID(requested.hasPrefix(prefix) ? String(requested.dropFirst(prefix.count)) : requested))
                }
                OnJoin { state, ctx in
                    state.players.append(ctx.playerID.rawValue)
                }
                OnLeave { state, ctx in
                    state.players.removeAll { $0 == ctx.playerID.rawValue }
                    state.leaves += 1
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
            transport: transport,
            syncLagPolicy: nil
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
        await holdCounting(at: point).gate
    }

    /// `hold(at:)`, also returning the registry, which counts the router's arrivals at every
    /// point: a send the router attempts arrives at its point first (`sendingJoinResponse`,
    /// `sendingInitialSync`), whether or not the transport then drops it.
    func holdCounting(at point: LandRouterHoldPoint) async -> (gate: TestGate, registry: HoldRegistry<LandRouterHoldPoint>) {
        let gate = TestGate()
        let registry = HoldRegistry<LandRouterHoldPoint>().on(point, arrival: 1) { await gate.arrive() }
        await router.installHolds(registry.hook)
        return (gate, registry)
    }

    var players: [String] {
        get async { await keeper.currentState().players }
    }

    var leaves: Int {
        get async { await keeper.currentState().leaves }
    }

    /// Joins `firstPlayer` on a first session held at `.admitJoinEntry`, admits `secondPlayer`
    /// on a second session (a newer attempt), then releases the first: its older attempt
    /// reaches the membership queue after the newer admission.
    func olderAttemptAfterNewer(firstPlayer: String, secondPlayer: String, tag: String) async throws
        -> (first: SessionID, firstConnection: AttemptConnection, second: SessionID, secondConnection: AttemptConnection)
    {
        let first = SessionID("s-first-\(tag)")
        let firstConnection = await connect(first)
        let admitGate = TestGate()
        await adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.admitJoinEntry, arrival: 1) { await admitGate.arrive() }.hook)
        let firstJoin = try startJoin(first, requestID: "join-first", player: firstPlayer)
        #expect(await admitGate.waitForArrivals(1))

        let second = SessionID("s-second-\(tag)")
        let secondConnection = await connect(second)
        await router.onMessage(try joinFrame("join-second", player: secondPlayer), from: second)
        #expect(await secondConnection.waitForJoinResponse(), "the newer session's join was answered")
        #expect(await adapter.isJoined(sessionID: second))

        admitGate.open()
        await firstJoin.value
        return (first, firstConnection, second, secondConnection)
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

    @Test("A disconnect handled by the adapter before the admission is queued: the admission is refused")
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
        #expect(await h.adapter.staleJoinAttemptsRefused == 1, "refused in the membership queue's order")
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
        _ = await h.connect(session)
        let (gate, registry) = await h.holdCounting(at: .afterAdmit)
        let join = try h.startJoin(session, requestID: "join-1", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: session)
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
        // The router attempts no send for the stale attempt (in-turn, the JoinResponse is the
        // flip's, which may have run before the disconnect).
        #expect(registry.arrivalCount(at: .sendingJoinResponse) == 0, "no JoinResponse to the gone session")
        #expect(registry.arrivalCount(at: .sendingInitialSync) == 0)
        #expect(!(await h.router.hasHandshakePhase(session)), "nothing re-added it since")
    }

    @Test("A stale attempt's undo after its admission spares a new connection that joined under the same ID (#945)")
    func staleUndoSparesAReusedID() async throws {
        let h = try await AttemptHarness.make()
        let session = SessionID("s-reused-after-admit")
        // One entry: the next session to end evicts this one, as 4096 would. An ID in the
        // ended set can't be admitted again, so only an evicted one can take a new connection.
        await h.adapter.setEndedSessionCapacityForTesting(1)
        _ = await h.connect(session)
        let oldGeneration = try #require(await h.transport.connectionGeneration(for: session))
        // Only the first attempt holds (arrival 1).
        let (gate, _) = await h.holdCounting(at: .afterAdmit)
        let oldJoin = try h.startJoin(session, requestID: "join-old", player: "p1")
        #expect(await gate.waitForArrivals(1))
        // The first attempt goes stale; its disconnect reaches the adapter, then another
        // session's end evicts the ID from the ended set.
        await h.transport.handleDisconnection(sessionID: session)
        await h.router.waitForDisconnectForwardsForTesting()
        await h.adapter.onDisconnect(sessionID: SessionID("s-evictor"), clientID: ClientID("c-evictor"))

        // A new connection under the same ID joins, while the first attempt is held.
        let reused = await h.connect(session)
        let reusedGeneration = try #require(await h.transport.connectionGeneration(for: session))
        #expect(reusedGeneration != oldGeneration)
        await h.router.onMessage(try h.joinFrame("join-new", player: "p1"), from: session)
        #expect(await reused.waitForJoinResponse(), "the new connection's join was answered")
        #expect(await h.adapter.isJoined(sessionID: session))

        // The first attempt's undo is for its own connection only.
        gate.open()
        await oldJoin.value
        await h.adapter.waitForOutboundIdleForTesting()
        #expect(await h.adapter.isJoined(sessionID: session), "the stale undo removed the new connection's membership")
        #expect(await h.players == ["p1"])
        #expect(await h.keeper.playerCount() == 1)
        #expect(await h.router.getBoundLandID(for: session) == h.container.landID)
        #expect(await !reused.closed)
        await h.keeper.forceShutdown()
    }

    @Test("A reconnect with a new SessionID while the old join is held: each touches only its own session")
    func reconnectWithNewID() async throws {
        let h = try await AttemptHarness.make()
        let old = SessionID("s-old")
        _ = await h.connect(old)
        let (gate, registry) = await h.holdCounting(at: .afterAdmit)
        let oldJoin = try h.startJoin(old, requestID: "join-old", player: "p1")
        #expect(await gate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: old)

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
        // In-turn, the router sends neither for the new join; the old attempt adds none.
        #expect(registry.arrivalCount(at: .sendingJoinResponse) == 0, "the old join sends no JoinResponse")
        #expect(registry.arrivalCount(at: .sendingInitialSync) == 0)
    }

    @Test("A stale attempt on its way into admitJoin while the player rejoins: the newer session survives")
    func rejoinWhileAdmissionOnItsWay() async throws {
        let h = try await AttemptHarness.make()
        let old = SessionID("s-old-entry")
        _ = await h.connect(old)
        // Past the router's last check, inside `admitJoin` but not yet queued.
        let admitGate = TestGate()
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.admitJoinEntry, arrival: 1) { await admitGate.arrive() }.hook)
        let forwardGate = await h.hold(at: .disconnectForwarded)
        let oldJoin = try h.startJoin(old, requestID: "join-old", player: "p1")
        #expect(await admitGate.waitForArrivals(1))
        await h.transport.handleDisconnection(sessionID: old)
        #expect(await forwardGate.waitForArrivals(1))
        forwardGate.open()

        let new = SessionID("s-new-entry")
        let newConnection = await h.connect(new)
        await h.router.onMessage(try h.joinFrame("join-new", player: "p1"), from: new)
        #expect(await attemptPoll { await h.adapter.isJoined(sessionID: new) })

        admitGate.open()
        await oldJoin.value
        #expect(await h.adapter.staleJoinAttemptsRefused == 1, "the old attempt isn't admitted")
        #expect(await h.adapter.isJoined(sessionID: new), "the newer session is not superseded")
        #expect(await h.adapter.supersededSessionCount == 0)
        #expect(!(await newConnection.closed))
        #expect(await h.players == ["p1"])
        #expect(await h.keeper.playerCount() == 1)
    }

    @Test("Two live sessions of one player: an older attempt admitted after a newer one is refused")
    func olderAttemptAfterNewerAdmission() async throws {
        let h = try await AttemptHarness.make()
        let first = SessionID("s-first")
        let firstConnection = await h.connect(first)
        let admitGate = TestGate()
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.admitJoinEntry, arrival: 1) { await admitGate.arrive() }.hook)
        let firstJoin = try h.startJoin(first, requestID: "join-first", player: "p1")
        #expect(await admitGate.waitForArrivals(1))

        // A newer attempt of the same player, on another live session, is admitted first.
        let second = SessionID("s-second-live")
        let secondConnection = await h.connect(second)
        await h.router.onMessage(try h.joinFrame("join-second", player: "p1"), from: second)
        #expect(await attemptPoll { await h.adapter.isJoined(sessionID: second) })

        admitGate.open()
        await firstJoin.value
        #expect(await h.adapter.staleJoinAttemptsRefused == 1)
        #expect(await h.adapter.isJoined(sessionID: second), "newest wins: the older attempt doesn't supersede it")
        #expect(!(await secondConnection.closed))
        #expect(await attemptPoll { await firstConnection.errorCodes == [ErrorCode.joinDenied.rawValue] })
        #expect(await h.router.getBoundLandID(for: first) == nil)
        #expect(await h.keeper.playerCount() == 1)
    }

    @Test(
        "A mapped player: an older attempt for an alias, admitted after the player's newer session, is refused by the resolved player (#234)"
    )
    func mappedOlderAttemptAfterNewerAdmission() async throws {
        let h = try await AttemptHarness.make()
        let r = try await h.olderAttemptAfterNewer(firstPlayer: "alias-p1", secondPlayer: "p1", tag: "mapped")
        #expect(await h.adapter.staleJoinAttemptsRefused == 1)
        #expect(await h.adapter.isJoined(sessionID: r.second), "newest wins: the older attempt doesn't supersede it")
        #expect(await h.adapter.supersededSessionCount == 0)
        #expect(!(await r.secondConnection.closed))
        #expect(await h.leaves == 0, "the keeper didn't kick the newer session")
        #expect(await r.firstConnection.waitForErrorCodes([ErrorCode.joinDenied.rawValue]))
        #expect(await h.router.getBoundLandID(for: r.first) == nil)
        #expect(await h.players == ["p1"])
        #expect(await h.keeper.playerCount() == 1)
    }

    @Test("A mapped player: a newer attempt for an alias supersedes the player's older session (#234)")
    func mappedNewerAttemptSupersedes() async throws {
        let h = try await AttemptHarness.make()
        let older = SessionID("s-older-mapped")
        let olderConnection = await h.connect(older)
        await h.router.onMessage(try h.joinFrame("join-older", player: "p1"), from: older)
        #expect(await olderConnection.waitForJoinResponse())
        #expect(await h.adapter.isJoined(sessionID: older))

        let newer = SessionID("s-newer-mapped")
        let newerConnection = await h.connect(newer)
        await h.router.onMessage(try h.joinFrame("join-newer", player: "alias-p1"), from: newer)
        #expect(await newerConnection.waitForJoinResponse())
        #expect(await h.adapter.isJoined(sessionID: newer))
        #expect(await h.adapter.staleJoinAttemptsRefused == 0)
        #expect(await h.adapter.isJoined(sessionID: older) == false, "the older session is superseded")
        #expect(!(await newerConnection.closed))
        #expect(await h.players == ["p1"])
        #expect(await h.keeper.playerCount() == 1)
    }
}

@Suite("LandRouter: a failed join's final frame carries its connection (#911)", .timeLimit(.minutes(1)))
struct LandRouterFlipFailureGenerationTests {
    @Test("A superseded failed join's final frame doesn't close a new connection that took its ID")
    func finalFrameSparesAReusedID() async throws {
        let h = try await AttemptHarness.make()
        let a = SessionID("s-a"), a2 = SessionID("s-a2")
        // A's join stays pending (no flip), and its second deferred frame fails it. No flip
        // timer: A2's join, held the same way, doesn't fail on its own.
        await h.adapter.setJoinFlipHeldForTesting(true)
        await h.adapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
        await h.adapter.setDeferredInboundLimitForTesting(count: 1, bytes: 1 << 20)
        let first = await h.connect(a)
        let oldGeneration = try #require(await h.transport.connectionGeneration(for: a))
        // The router returns after the admission; the flip wait runs in a Task of its own.
        try await h.startJoin(a, requestID: "join-a", player: "p1").value
        #expect(await h.router.isJoinPending(a), "admitted, waiting for its flip")

        // The failure path is held at its start, and its end (A's, the only join that fails
        // here) is the event the test waits for.
        let failed = TestGate(), handled = TestGate()
        handled.open()
        await h.router.installHolds(HoldRegistry<LandRouterHoldPoint>()
            .on(.flipFailed, arrival: 1) { await failed.arrive() }
            .on(.flipFailureHandled, arrival: 1) { await handled.arrive() }
            .hook)
        let action = try anyAction()
        await h.router.onMessage(action, from: a)
        await h.router.onMessage(action, from: a)
        #expect(await failed.waitForArrivals(1), "A's join failed (inbound overflow) and its flip wait is held")

        // While the router holds A's failure: a newer join of p1 supersedes A, A's 4017 goes
        // out, A's client goes, and a new connection takes the ID before the router sends.
        // A's close is the test's precondition: A must be ended when the router sends, so
        // its final frame takes the ended branch (F1 pins the 4017's order).
        _ = await h.connect(a2)
        try await h.startJoin(a2, requestID: "join-a2", player: "p1").value
        #expect(await first.waitUntilClosed(), "A was closed by its supersede")
        await h.transport.handleDisconnection(sessionID: a)
        let reused = AttemptConnection()
        #expect(await h.transport.handleConnection(sessionID: a, connection: reused, authInfo: nil) == .accepted)
        let reusedGeneration = try #require(await h.transport.connectionGeneration(for: a))
        #expect(reusedGeneration != oldGeneration)

        // The router sends A's JOIN_INBOUND_OVERFLOW and its close, for A's old connection,
        // then A's adapter cleanup. (A2's flip stays held, so a wait for no pending flip
        // wouldn't return.)
        failed.open()
        #expect(await handled.waitForArrivals(1), "the router's failure path for A ended")
        await h.adapter.waitForOutboundIdleForTesting()
        // No close marker is on the new connection's queue: a frame for it still goes out.
        let dropsBefore = await h.transport.framesDroppedAfterCloseMarker
        await h.transport.sendSessionFrames([SessionFrame(data: Data("hello".utf8), sessionID: a, connectionGeneration: reusedGeneration)])
        #expect(await h.transport.framesDroppedAfterCloseMarker == dropsBefore, "the old connection's close reached the new one")
        await h.transport.flushSessionQueues()
        #expect(await reused.frames == [Data("hello".utf8)])
        #expect(await !reused.closed, "the old connection's close closed the new one")
        await h.router.installHolds(nil)
        await h.keeper.forceShutdown()
    }

    /// How the pending join fails at its flip in `flipStageJoinDeniedSparesAReusedID`.
    enum FlipStageFailure: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// A newer join of the player is admitted while the flip waits.
        case superseded
        /// The land is torn down while the flip waits.
        case landClosed
        var testDescription: String { rawValue }
    }

    @Test(
        "A flip-stage JOIN_DENIED is for the connection that joined: a new connection that took the ID doesn't get it (#941)",
        arguments: FlipStageFailure.allCases
    )
    func flipStageJoinDeniedSparesAReusedID(_ stage: FlipStageFailure) async throws {
        let h = try await AttemptHarness.make()
        let a = SessionID("s-a-\(stage.rawValue)")
        // A's join stays pending (no flip) until the failure below ends it.
        await h.adapter.setJoinFlipHeldForTesting(true)
        await h.adapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
        let first = await h.connect(a)
        let oldGeneration = try #require(await h.transport.connectionGeneration(for: a))
        try await h.startJoin(a, requestID: "join-a", player: "p1").value
        #expect(await h.router.isJoinPending(a), "admitted, waiting for its flip")

        // The failure path is held after it read A's generation and ended the attempt,
        // before it sends the JOIN_DENIED. For a supersede, the router's handling of the 4017's
        // disconnect is held at its entry too: otherwise it ends A's attempt before the flip
        // wait resumes, and the failure path returns without an answer.
        let failed = TestGate(), handled = TestGate(), disconnect = TestGate()
        handled.open()
        defer { disconnect.open() }
        let holds = HoldRegistry<LandRouterHoldPoint>()
            .on(.flipFailed, arrival: 1) { await failed.arrive() }
            .on(.flipFailureHandled, arrival: 1) { await handled.arrive() }
        if stage == .superseded {
            _ = holds.on(.disconnectEntry, arrival: 1) { await disconnect.arrive() }
        }
        await h.router.installHolds(holds.hook)
        // The newer join's handler, when there is one; awaited after the release.
        var newerJoin: Task<Void, Never>?
        switch stage {
        case .superseded:
            // A newer join of p1, on another session, supersedes A; A's 4017 goes out.
            let a2 = SessionID("s-a2-\(stage.rawValue)")
            _ = await h.connect(a2)
            newerJoin = try h.startJoin(a2, requestID: "join-a2", player: "p1")
            #expect(await failed.waitForArrivals(1), "A's join failed (superseded) and its failure path is held")
            // The server close tells the router first, then closes the connection; the
            // connection's own disconnect callback follows, and A's client is gone.
            #expect(await disconnect.waitForArrivals(1), "the 4017's disconnect reached the router")
            disconnect.open()
            #expect(await first.waitUntilClosed(), "A was closed by its supersede")
            await h.transport.handleDisconnection(sessionID: a)
            #expect(await attemptPoll { await !h.router.hasHandshakePhase(a) }, "the router handled A's disconnect")
        case .landClosed:
            await h.adapter.endSessionTicketsForTeardown()
            #expect(await failed.waitForArrivals(1), "A's join failed (land closed) and its failure path is held")
            // A's client goes.
            await h.transport.handleDisconnection(sessionID: a)
        }

        // While the router holds A's failure, a new connection takes the ID.
        let reused = AttemptConnection()
        #expect(await h.transport.handleConnection(sessionID: a, connection: reused, authInfo: nil) == .accepted)
        let reusedGeneration = try #require(await h.transport.connectionGeneration(for: a))
        #expect(reusedGeneration != oldGeneration)
        let staleDropsBefore = await h.transport.framesDroppedStaleGeneration

        failed.open()
        #expect(await handled.waitForArrivals(1), "the router's failure path for A ended")
        await newerJoin?.value
        await h.adapter.waitForOutboundIdleForTesting()
        await h.transport.flushSessionQueues()
        // A is back in the handshake, so the error took the transport branch, named for A's
        // old connection, which is gone: the transport drops it.
        #expect(await h.transport.framesDroppedStaleGeneration == staleDropsBefore + 1, "the JOIN_DENIED wasn't named for A's old connection")
        let reusedCodes = await reused.errorCodes
        #expect(reusedCodes.isEmpty, "the new connection got A's error: \(reusedCodes)")
        #expect(await !reused.closed)
        await h.router.installHolds(nil)
        await h.keeper.forceShutdown()
    }

    @Test("A failed join's later frames are dropped: its error and 1000 aren't overtaken by the refused-frame budget's 1008 (#912)")
    func failedJoinDropsLaterFrames() async throws {
        let h = try await AttemptHarness.make()
        let a = SessionID("s-a")
        await h.adapter.setJoinFlipHeldForTesting(true)
        await h.adapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
        await h.adapter.setDeferredInboundLimitForTesting(count: 1, bytes: 1 << 20)
        let connection = await h.connect(a)
        try await h.startJoin(a, requestID: "join-a", player: "p1").value
        #expect(await h.router.isJoinPending(a), "admitted, waiting for its flip")

        // The connection's sends are held, so the failure's error stays queued while the
        // client keeps sending. Its send attempt is the event that the failure reached the
        // writer: the router decided it, in the segment that ended the attempt.
        await connection.holdSends()
        let before = await connection.sendAttempts
        let action = try anyAction()
        await h.router.onMessage(action, from: a)
        await h.router.onMessage(action, from: a)
        #expect(await connection.attempted.waitForArrivals(before + 1), "A's JOIN_INBOUND_OVERFLOW reached the connection's send")

        // More frames than the pre-join refusal budget (8): none is refused or counted.
        let dropsBefore = await h.router.framesDroppedAfterRefusalForTesting
        for _ in 0..<(HandshakeFrameLimit.defaultMaxRefusedFrames + 2) {
            await h.router.onMessage(action, from: a)
        }
        #expect(await h.router.framesDroppedAfterRefusalForTesting == dropsBefore + HandshakeFrameLimit.defaultMaxRefusedFrames + 2)

        await connection.releaseSends()
        #expect(await connection.waitUntilClosed())
        await h.adapter.waitForOutboundIdleForTesting()
        await h.transport.flushSessionQueues()
        let errorCodes = await connection.errorCodes, closeCodes = await connection.closeCodes
        #expect(errorCodes == [ErrorCode.joinInboundOverflow.rawValue], "\(errorCodes)")
        #expect(closeCodes == [1000], "\(closeCodes)")
        await h.keeper.forceShutdown()
    }

    private func anyAction() throws -> Data {
        try JSONEncoder().encode(TransportMessage.action(
            requestID: "act", action: ActionEnvelope(typeIdentifier: "Anything", payload: AnyCodable([String: Int]()))
        ))
    }
}
