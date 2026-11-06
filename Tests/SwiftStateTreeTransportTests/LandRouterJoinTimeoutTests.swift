// Tests/SwiftStateTreeTransportTests/LandRouterJoinTimeoutTests.swift
//
// The end-to-end join budget (#104, `JOIN_TIMEOUT_MS`). Budgets of a few milliseconds, with
// the join held at the router's, the manager's or the budget timer's hold points, so each
// interleaving is forced rather than timed.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct JoinTimeoutState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [String] = []
}

/// Records each frame sent and the close.
private actor TimeoutConnection: WebSocketConnection {
    private(set) var frames: [Data] = []
    private(set) var closed = false

    func send(_ data: Data) async throws { frames.append(data) }
    func close() async throws { closed = true }

    var errors: [ErrorPayload] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
            .compactMap { if case .error(let payload) = $0.payload { return payload } else { return nil } }
    }

    /// Whether the last frame is an error.
    var lastIsError: Bool {
        guard let last = frames.last, let message = try? JSONDecoder().decode(TransportMessage.self, from: last) else { return false }
        if case .error = message.payload { return true }
        return false
    }

    var joinResponses: Int {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
            .filter { $0.kind == .joinResponse }.count
    }
}

private func timeoutPoll(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(5))
    }
    return await condition()
}

private let short = Duration.milliseconds(20)
private let generous = Duration.seconds(30)

/// A router, its transport, its manager and one land ("one").
private struct TimeoutHarness {
    let transport: WebSocketTransport
    let router: LandRouter<JoinTimeoutState>
    let manager: LandManager<JoinTimeoutState>
    let container: LandContainer<JoinTimeoutState>
    let metrics = JoinTimeoutMetrics()

    var adapter: TransportAdapter<JoinTimeoutState> { container.transportAdapter }

    static func make(budget: Duration) async throws -> TimeoutHarness {
        let definition = Land("join-timeout", using: JoinTimeoutState.self) {
            Rules {
                OnJoin { (state: inout JoinTimeoutState, ctx: LandContext) in
                    state.players.append(ctx.playerID.rawValue)
                }
                OnLeave { (state: inout JoinTimeoutState, ctx: LandContext) in
                    state.players.removeAll { $0 == ctx.playerID.rawValue }
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in JoinTimeoutState() }
        )
        let manager = LandManager<JoinTimeoutState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in JoinTimeoutState() },
            transport: transport
        )
        let router = LandRouter<JoinTimeoutState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)
        let landID = LandID(landType: "join-timeout", instanceId: "one")
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: JoinTimeoutState(), metadata: [:])
        let harness = TimeoutHarness(transport: transport, router: router, manager: manager, container: container)
        await router.setJoinTimeoutMetricsForTesting(harness.metrics)
        await router.setJoinTimeoutForTesting(budget)
        return harness
    }

    func connect(_ session: SessionID) async -> TimeoutConnection {
        let connection = TimeoutConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return connection
    }

    /// Sends a join from a Task of its own; the task ends when the router's handler returns.
    func startJoin(_ session: SessionID, instance: String = "one", player: String) throws -> Task<Void, Never> {
        let frame = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-\(player)", landType: "join-timeout", landInstanceId: instance,
            playerID: player, deviceID: nil, metadata: nil
        ))
        let router = self.router
        return Task { await router.onMessage(frame, from: session) }
    }

    var players: [String] {
        get async { await container.keeper.currentState().players }
    }

    /// The session was timed out: one JOIN_DENIED with `message`, then the close.
    func expectTimedOut(_ connection: TimeoutConnection, _ phase: JoinTimeoutPhase) async {
        #expect(await timeoutPoll { await connection.closed }, "the session is closed")
        // Nothing was dropped on the way: the error went out before the close.
        let frameCount = await connection.frames.count
        #expect(await transport.framesDroppedAfterSendFailure == 0, "frames: \(frameCount)")
        #expect(await transport.framesDroppedAfterCloseMarker == 0, "frames: \(frameCount)")
        #expect(await transport.framesDroppedMissingSession == 0, "frames: \(frameCount)")
        #expect(await transport.framesDroppedStaleGeneration == 0, "frames: \(frameCount)")
        let errors = await connection.errors
        let received = await connection.frames.map { String(decoding: $0, as: UTF8.self) }
        #expect(errors.map(\.code) == [ErrorCode.joinDenied.rawValue], "received: \(received)")
        #expect(errors.first?.message == phase.message)
        #expect(errors.first?.message.hasPrefix("Join timed out") == true)
        #expect(metrics.snapshot[phase] == 1)
    }
}

@Suite("LandRouter: the end-to-end join budget (#104)", .timeLimit(.minutes(1)))
struct LandRouterJoinTimeoutTests {
    /// Holds the budget's timer before its check, and the join at `point`; returns both gates.
    private func holdTimer(_ h: TimeoutHarness, andRouterAt point: LandRouterHoldPoint) async -> (timer: TestGate, join: TestGate) {
        let timer = TestGate(), join = TestGate()
        let registry = HoldRegistry<LandRouterHoldPoint>()
            .on(.joinBudgetExpired, arrival: 1) { await timer.arrive() }
            .on(point, arrival: 1) { await join.arrive() }
        await h.router.installHolds(registry.hook)
        return (timer, join)
    }

    @Test("Out of budget during the land lookup: JOIN_DENIED naming the phase, then the close; the late creation binds nothing")
    func timedOutDuringLandLookup() async throws {
        let h = try await TimeoutHarness.make(budget: short)
        let creation = TestGate(), timer = TestGate()
        defer { creation.open(); timer.open() }
        await h.manager.installHolds(HoldRegistry.at(.creation) { await creation.arrive() })
        await h.router.installHolds(HoldRegistry.at(.joinBudgetExpired) { await timer.arrive() })
        let session = SessionID("s-lookup")
        let connection = await h.connect(session)

        let join = try h.startJoin(session, instance: "new", player: "p1")
        #expect(await creation.waitForArrivals(1))
        #expect(await timer.waitForArrivals(1))
        #expect(!(await connection.closed), "still connected before the timeout")
        let drain = await h.transport.sendQueueDrainTaskForTesting(session)
        #expect(drain != nil, "the transport still holds the session before the timeout")
        #expect(drain?.isCancelled == false, "its drain isn't cancelled")
        timer.open()
        await h.expectTimedOut(connection, .landLookup)
        #expect(await h.router.lookupTimeoutFramesForTesting == 1, "the error was handed to the transport")
        #expect(drain?.isCancelled == true, "the close cancels the drain")

        creation.open()
        await join.value
        #expect(await h.router.getBoundLandID(for: session) == nil)
        #expect(!(await h.router.isJoining(session)))
    }

    @Test("Out of budget before the admission started: JOIN_DENIED naming the phase, then the close; the admission never happens")
    func timedOutWaitingForAdmission() async throws {
        let h = try await TimeoutHarness.make(budget: short)
        let (timer, gate) = await holdTimer(h, andRouterAt: .beforeAdmit)
        defer { timer.open(); gate.open() }
        let session = SessionID("s-admission")
        let connection = await h.connect(session)

        let join = try h.startJoin(session, player: "p1")
        #expect(await gate.waitForArrivals(1))
        #expect(await timer.waitForArrivals(1))
        timer.open()
        await h.expectTimedOut(connection, .admission)

        gate.open()
        await join.value
        #expect(await h.players == [], "no keeper join")
        #expect(!(await h.adapter.isJoined(sessionID: session)))
        #expect(!(await h.adapter.isJoining(session)))
    }

    @Test("An admission on its way to the membership queue when the budget runs out is refused: no member, no keeper player")
    func admissionOnItsWayIsRefused() async throws {
        let h = try await TimeoutHarness.make(budget: short)
        let timer = TestGate(), entry = TestGate()
        defer { timer.open(); entry.open() }
        await h.router.installHolds(HoldRegistry.at(.joinBudgetExpired) { await timer.arrive() })
        await h.adapter.installHolds(HoldRegistry.at(.admitJoinEntry) { await entry.arrive() })
        let session = SessionID("s-on-its-way")
        let connection = await h.connect(session)

        let join = try h.startJoin(session, player: "p1")
        #expect(await entry.waitForArrivals(1))
        #expect(await timer.waitForArrivals(1))
        timer.open()
        await h.expectTimedOut(connection, .admission)

        entry.open()
        await join.value
        #expect(await h.adapter.staleJoinAttemptsRefused == 1, "refused before the keeper's join")
        #expect(await h.players == [])
        #expect(!(await h.adapter.isJoined(sessionID: session)))
        #expect(!(await h.adapter.isJoining(session)))
        #expect(await connection.joinResponses == 0)
        #expect(await connection.lastIsError)
    }

    @Test("An admission done before the budget ran out, which the router hasn't seen yet, is left alone: the join completes")
    func admissionDoneIsLeftAlone() async throws {
        let h = try await TimeoutHarness.make(budget: short)
        await h.adapter.setJoinFlipLimitsForTesting(timeout: generous, budget: nil)
        let (timer, gate) = await holdTimer(h, andRouterAt: .afterAdmit)
        defer { timer.open(); gate.open() }
        let session = SessionID("s-done")
        let connection = await h.connect(session)

        let join = try h.startJoin(session, player: "p1")
        #expect(await gate.waitForArrivals(1))
        #expect(await timer.waitForArrivals(1))
        timer.open()
        #expect(await timeoutPoll { await h.router.joinBudgetChecksForTesting == 1 })
        // The adapter's answer comes back to the router after the check: wait for the attempt
        // to be left as it was.
        #expect(await timeoutPoll { await h.router.isJoining(session) })

        gate.open()
        await join.value
        #expect(await timeoutPoll { await connection.joinResponses == 1 }, "the join completes")
        #expect(await connection.errors.isEmpty)
        #expect(!(await connection.closed))
        #expect(await h.players == ["p1"])
        #expect(h.metrics.snapshot.values.allSatisfy { $0 == 0 })
    }

    @Test("A budget that runs out after the router's admission does nothing: the join completes")
    func admittedInTimeIsLeftAlone() async throws {
        let h = try await TimeoutHarness.make(budget: short)
        let adapter = h.adapter
        await adapter.setJoinFlipLimitsForTesting(timeout: generous, budget: nil)
        // In-turn: no sync phase commits until released, so the join stays admitted, unflipped.
        await adapter.setSyncPlanFaultForTesting { throw JoinTimeoutTestFault() }
        let timer = TestGate(), admission = TestGate()
        defer { timer.open(); admission.open() }
        let registry = HoldRegistry<LandRouterHoldPoint>()
            .on(.joinBudgetExpired, arrival: 1) { await timer.arrive() }
            .on(.beforeAdmit, arrival: 1) { await admission.arrive() }
        await h.router.installHolds(registry.hook)
        let session = SessionID("s-in-time")
        let connection = await h.connect(session)

        let join = try h.startJoin(session, player: "p1")
        // The budget ran out (the timer is held before its check) while the join waits to be admitted.
        #expect(await timer.waitForArrivals(1))
        #expect(await admission.waitForArrivals(1))
        admission.open()
        await join.value
        #expect(await timeoutPoll { await h.players == ["p1"] }, "admitted")

        timer.open()
        #expect(await timeoutPoll { await h.router.joinBudgetChecksForTesting == 1 })
        #expect(await h.router.getBoundLandID(for: session) == h.container.landID, "still bound")
        #expect(!(await connection.closed))
        #expect(h.metrics.snapshot.values.allSatisfy { $0 == 0 })

        await adapter.setSyncPlanFaultForTesting(nil)
        #expect(await timeoutPoll { await connection.joinResponses == 1 }, "the join completes")
        #expect(await connection.errors.isEmpty)
    }

    @Test(
        "An in-turn join admitted after its budget ran out gets no flip wait: JOIN_DENIED naming the flip",
        .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: the in-turn join path is off")
    )
    func flipWaitsForWhatIsLeft() async throws {
        let h = try await TimeoutHarness.make(budget: short)
        let adapter = h.adapter
        // No sync phase commits, so the join can't flip before its flip waiter times out.
        await adapter.setSyncPlanFaultForTesting { throw JoinTimeoutTestFault() }
        let timer = TestGate(), admission = TestGate()
        defer { timer.open(); admission.open() }
        let registry = HoldRegistry<LandRouterHoldPoint>()
            .on(.joinBudgetExpired, arrival: 1) { await timer.arrive() }
            .on(.beforeAdmit, arrival: 1) { await admission.arrive() }
        await h.router.installHolds(registry.hook)
        let session = SessionID("s-flip")
        let connection = await h.connect(session)

        let join = try h.startJoin(session, player: "p1")
        #expect(await timer.waitForArrivals(1))
        #expect(await admission.waitForArrivals(1))
        // Admitted with the budget spent: the flip waiter's timeout is zero.
        admission.open()
        await join.value
        await h.expectTimedOut(connection, .flip)
        #expect(await adapter.inTurnJoinFailures[.timeout] == 1)
        await adapter.setSyncPlanFaultForTesting(nil)
    }

    @Test("JOIN_TIMEOUT_MS and the deprecated JOIN_FLIP_TIMEOUT_MS")
    func environment() {
        #expect(JoinTimeoutConfig.parseBudget(environment: [:]) == .milliseconds(12_000))
        #expect(JoinTimeoutConfig.parseBudget(environment: ["JOIN_TIMEOUT_MS": "3000"]) == .milliseconds(3_000))
        #expect(JoinTimeoutConfig.parseBudget(environment: ["JOIN_TIMEOUT_MS": "0"]) == nil)
        #expect(JoinTimeoutConfig.parseBudget(environment: ["JOIN_TIMEOUT_MS": "-5"]) == .milliseconds(12_000))
        #expect(JoinTimeoutConfig.parseBudget(environment: ["JOIN_TIMEOUT_MS": "soon"]) == .milliseconds(12_000))
        #expect(JoinTimeoutConfig.parseDeprecatedFlipTimeout(environment: [:]) == nil)
        #expect(JoinTimeoutConfig.parseDeprecatedFlipTimeout(environment: ["JOIN_FLIP_TIMEOUT_MS": "4000"]) == .milliseconds(4_000))
        #expect(JoinTimeoutConfig.parseDeprecatedFlipTimeout(environment: ["JOIN_FLIP_TIMEOUT_MS": "0"]) == .milliseconds(1))

        let now = ContinuousClock.now
        #expect(JoinTimeoutConfig.flipWait(deadline: now + .seconds(3), now: now, cap: nil) == .seconds(3))
        #expect(JoinTimeoutConfig.flipWait(deadline: now - .seconds(1), now: now, cap: nil) == .zero)
        #expect(JoinTimeoutConfig.flipWait(deadline: now + .seconds(3), now: now, cap: .seconds(1)) == .seconds(1))
        #expect(JoinTimeoutConfig.flipWait(deadline: nil, now: now, cap: .seconds(1)) == .seconds(1))
        #expect(JoinTimeoutConfig.flipWait(deadline: nil, now: now, cap: nil) == nil)
        #expect(JoinTimeoutPhase.landLookup.message == "Join timed out during land lookup")
        #expect(TransportProfilingActor.joinTimeoutsKey(.landLookup) == "joinTimeoutsLandLookup")
    }
}

struct JoinTimeoutTestFault: Error {}
