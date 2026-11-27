// Tests/SwiftStateTreeTransportTests/RoutedJoinSupersededTests.swift
//
// A routed join whose keeper entry is replaced while its OnJoin resolvers run fails with
// `JoinError.superseded` (#860). The router answers it like the flip-stage supersede (#861): the
// `JOIN_DENIED` error is the session's last frame, with the 4017 `superseded` close behind it, so
// the client doesn't rejoin into a kick loop. That holds whoever answers: the join's handler, or
// the join budget's timer that the handler left the answer to; and whichever stage refused it:
// the pending OnJoin, or the kick's fence (J2c), when a later join arrived while the routed join
// waited in its kick. Hosted joins of one player are serialized by the adapter's membership
// queue, so here a direct keeper caller makes the newer join.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct RoutedSupersedeState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: [String] = []
}

@PlainData
struct RoutedSupersedeOutput: ResolverOutput {}

/// Holds the OnJoin resolver of a session registered here.
private enum RoutedSupersedeHold {
    static let gates = KeyedGates<SessionID, TestGate> { TestGate() }
}

/// Holds the OnLeave resolver of a session registered here: the kick of that session's entry.
private enum RoutedLeaveHold {
    static let gates = KeyedGates<SessionID, TestGate> { TestGate() }
}

struct RoutedLeaveResolver: ContextResolver {
    typealias Output = RoutedSupersedeOutput

    static func resolve(ctx: ResolverContext) async throws -> RoutedSupersedeOutput {
        if let gate = RoutedLeaveHold.gates.registeredGate(ctx.sessionID) {
            await gate.arrive()
        }
        return RoutedSupersedeOutput()
    }
}

struct RoutedSupersedeResolver: ContextResolver {
    typealias Output = RoutedSupersedeOutput

    static func resolve(ctx: ResolverContext) async throws -> RoutedSupersedeOutput {
        if let gate = RoutedSupersedeHold.gates.registeredGate(ctx.sessionID) {
            await gate.arrive()
        }
        return RoutedSupersedeOutput()
    }
}

/// Records what the transport sends to one session and how it was closed, as one ordered log:
/// `error:<code>:<message>` for an error frame, `frame` for any other, `close:<code>`. Tests
/// wait on the log (`waitFor`), not on time.
private actor RoutedSupersedeConnection: WebSocketConnection {
    private(set) var events: [String] = []
    private var waiters: [UInt64: (condition: @Sendable ([String]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextWaiter: UInt64 = 0

    func send(_ data: Data, kind: WebSocketFrameKind) async throws {
        if let message = try? JSONDecoder().decode(TransportMessage.self, from: data),
           case .error(let payload) = message.payload {
            append("error:\(payload.code):\(payload.message)")
        } else {
            append("frame")
        }
    }

    func close() async throws { append("close:\(SessionClose.normal.code)") }
    func close(with close: SessionClose) async throws { append("close:\(close.code)") }

    private func append(_ event: String) {
        events.append(event)
        for (id, waiter) in waiters where waiter.condition(events) {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    /// Returns once `condition` holds, or once the task is cancelled (`withinHangBound`); the
    /// expectations after the wait then fail.
    func waitFor(_ condition: @escaping @Sendable ([String]) -> Bool) async {
        if condition(events) || Task.isCancelled { return }
        nextWaiter += 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                waiters[id] = (condition, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

/// Everything a superseded session gets: the error as its only and last frame, then the 4017
/// close.
private let supersededAnswer = [
    "error:\(ErrorCode.joinDenied.rawValue):Join superseded by a newer join of the player",
    "close:\(SessionClose.Code.superseded)",
]

/// A router with a refused-frame budget of 0, so a counted refusal closes with 1008 at once
/// (the router closes on count > budget), its transport, its manager and the land ("one").
private struct RoutedSupersedeHarness {
    let transport: WebSocketTransport
    let router: LandRouter<RoutedSupersedeState>
    let container: LandContainer<RoutedSupersedeState>

    /// The land: OnJoin and OnLeave each run a resolver a test can hold by session.
    static func definition() -> LandDefinition<RoutedSupersedeState> {
        Land("routed-supersede", using: RoutedSupersedeState.self) {
            Rules {
                OnJoin(resolvers: RoutedSupersedeResolver.self) { state, _, ctx in
                    state.joins.append(ctx.clientID.rawValue)
                }
                OnLeave(resolvers: RoutedLeaveResolver.self) { _, _, _ in }
            }
        }
    }

    static func make(joinBudget: Duration? = nil) async throws -> RoutedSupersedeHarness {
        let definition = definition()
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in RoutedSupersedeState() }
        )
        let manager = LandManager<RoutedSupersedeState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in RoutedSupersedeState() },
            transport: transport
        )
        let router = LandRouter<RoutedSupersedeState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true,
            transportEncoding: .json,
            maxRefusedHandshakeFrames: 0
        )
        await transport.setDelegate(router)
        if let joinBudget { await router.setJoinTimeoutForTesting(joinBudget) }
        let landID = LandID(landType: "routed-supersede", instanceId: "one")
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: RoutedSupersedeState(), metadata: [:])
        return RoutedSupersedeHarness(transport: transport, router: router, container: container)
    }

    /// A connected session with a fresh key, and the gate its OnJoin resolver holds on.
    func connect() async -> (SessionID, RoutedSupersedeConnection, TestGate) {
        let session = RoutedSupersedeHold.gates.fresh { SessionID("s-routed-\($0)") }
        let connection = RoutedSupersedeConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return (session, connection, RoutedSupersedeHold.gates.gate(session))
    }

    /// The routed join of p1, sent from its own task: the transport handles the frame through
    /// the router's join, which parks at the held resolver. `ended` is arrived at once the
    /// router's handling returns.
    func startRoutedJoin(_ session: SessionID, ended: TestGate) throws -> Task<Void, Never> {
        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1", landType: "routed-supersede", landInstanceId: "one",
            playerID: "p1", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        ))
        let transport = self.transport
        return Task {
            await transport.handleIncomingMessage(sessionID: session, data: join)
            await ended.arrive()
        }
    }

    /// A direct keeper join of p1, which kicks the routed join's pending entry and joins. It
    /// runs in its own task and reports its end through a gate: the test never awaits a call
    /// that a regression could park. True when it ended without an error.
    func directJoin() async -> Bool {
        let keeper = container.keeper
        let ended = TestGate()
        defer { ended.open() }
        let direct = Task { () -> (any Error)? in
            defer { Task { await ended.arrive() } }
            do {
                try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c-direct"), sessionID: SessionID("s-direct"))
                return nil
            } catch {
                return error
            }
        }
        guard await ended.waitForArrivals(1) else {
            Issue.record("the direct join didn't end while the routed join was held")
            return false
        }
        let error = await direct.value
        #expect(error == nil, "the direct join threw \(String(describing: error))")
        return error == nil
    }

    /// Waits for the session's close, then checks that its whole log is the superseded answer
    /// (nothing else sent, nothing after the close) and that the direct join keeps the player:
    /// the land's OnJoin log is `joins`.
    func expectSupersededAnswer(_ connection: RoutedSupersedeConnection, joins: [String] = ["c-direct"], sourceLocation: SourceLocation = #_sourceLocation) async {
        let closed = await withinHangBound { await connection.waitFor { $0.contains { $0.hasPrefix("close:") } } }
        #expect(closed, "the session wasn't closed", sourceLocation: sourceLocation)
        #expect(await connection.events == supersededAnswer, sourceLocation: sourceLocation)
        #expect(await container.keeper.currentState().joins == joins, sourceLocation: sourceLocation)
    }
}

@Suite("A routed join superseded during its OnJoin resolvers (#860)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct RoutedJoinSupersededTests {
    @Test("Its JOIN_DENIED is the session's last frame, with the 4017 superseded close behind it; the newer join keeps the player")
    func supersededJoinClosesWith4017() async throws {
        let h = try await RoutedSupersedeHarness.make()
        let (session, connection, gate) = await h.connect()
        defer { gate.open() }
        let routedEnded = TestGate()
        defer { routedEnded.open() }
        let routed = try h.startRoutedJoin(session, ended: routedEnded)
        defer { routed.cancel() }
        guard await gate.waitForArrivals(1) else {
            Issue.record("the routed join's OnJoin resolver never ran")
            return
        }
        guard await h.directJoin() else { return }

        gate.open()
        await h.expectSupersededAnswer(connection)
    }

    @Test("The budget runs out during the resolvers, and the handler leaves its supersede to the timer: the timer answers it with the 4017 close")
    func timerAnswersTheLeftSupersede() async throws {
        let h = try await RoutedSupersedeHarness.make(joinBudget: .milliseconds(20))
        let timer = TestGate(), answered = TestGate()
        defer { timer.open(); answered.open() }
        await h.router.installHolds(HoldRegistry<LandRouterHoldPoint>()
            .on(.joinBudgetExpired, arrival: 1) { await timer.arrive() }
            .on(.joinBudgetAdmissionAnswered, arrival: 1) { await answered.arrive() }
            .hook)
        let (session, connection, gate) = await h.connect()
        defer { gate.open() }
        let routedEnded = TestGate()
        defer { routedEnded.open() }
        let routed = try h.startRoutedJoin(session, ended: routedEnded)
        defer { routed.cancel() }
        guard await gate.waitForArrivals(1) else {
            Issue.record("the routed join's OnJoin resolver never ran")
            return
        }
        // The timer is held until the admission is in the keeper's join (the resolver holds),
        // whenever the budget runs out: it asks the adapter only after that.
        guard await timer.waitForArrivals(1) else {
            Issue.record("the budget's timer never fired")
            return
        }
        timer.open()
        // The adapter said the admission is in the keeper's join, and the timer is held before
        // it re-checks the attempt (`expiring`).
        guard await answered.waitForArrivals(1) else {
            Issue.record("the budget's timer never asked the adapter")
            return
        }
        guard await h.directJoin() else { return }

        gate.open()
        // The handler saw `.superseded` while the attempt was expiring: it left the answer.
        guard await routedEnded.waitForArrivals(1) else {
            Issue.record("the routed join's handler didn't return")
            return
        }
        #expect(await connection.events.isEmpty, "the handler left its answer to the timer")

        answered.open()
        await h.expectSupersededAnswer(connection)
    }

    @Test("The budget's timer runs after the keeper threw, before the router resumed: the timer leaves it to the handler, which answers with the 4017 close")
    func timerAfterTheKeeperThrewLeavesItToTheHandler() async throws {
        let h = try await RoutedSupersedeHarness.make(joinBudget: .milliseconds(20))
        let timer = TestGate(), afterAdmit = TestGate(), leftToHandler = TestGate()
        // `leftToHandler` only signals: the timer passes it at once, as its last step.
        leftToHandler.open()
        defer { timer.open(); afterAdmit.open() }
        await h.router.installHolds(HoldRegistry<LandRouterHoldPoint>()
            .on(.joinBudgetExpired, arrival: 1) { await timer.arrive() }
            .on(.afterAdmit, arrival: 1) { await afterAdmit.arrive() }
            .on(.joinBudgetLeftToHandler, arrival: 1) { await leftToHandler.arrive() }
            .hook)
        let (session, connection, gate) = await h.connect()
        defer { gate.open() }
        let routedEnded = TestGate()
        defer { routedEnded.open() }
        let routed = try h.startRoutedJoin(session, ended: routedEnded)
        defer { routed.cancel() }
        guard await gate.waitForArrivals(1) else {
            Issue.record("the routed join's OnJoin resolver never ran")
            return
        }
        guard await timer.waitForArrivals(1) else {
            Issue.record("the budget's timer never fired")
            return
        }
        guard await h.directJoin() else { return }

        // The keeper throws `.superseded`; the adapter's admission has returned (its expected
        // admission is gone), and the router is held before it resumes.
        gate.open()
        guard await afterAdmit.waitForArrivals(1) else {
            Issue.record("the routed join's admission didn't return")
            return
        }
        timer.open()
        // The timer asks the adapter, which says the keeper's join started, finds nothing left
        // to answer, clears `expiring` and returns. Only the handler can answer after this.
        guard await leftToHandler.waitForArrivals(1) else {
            Issue.record("the budget's timer didn't leave the attempt to the handler")
            return
        }
        #expect(await connection.events.isEmpty, "the timer didn't take a finished join for one never started")

        afterAdmit.open()
        await h.expectSupersededAnswer(connection)
    }

    @Test("A routed join fenced out at its kick (J2c) by a later join gets the 4017 close, never reaches OnJoin or the admission, and leaves no join bookkeeping")
    func fencedAtTheKickClosesWith4017() async throws {
        // No join budget: no deadline is part of the ordering.
        let h = try await RoutedSupersedeHarness.make(joinBudget: .zero)
        let adapter = h.container.transportAdapter
        // A holds the player; its OnLeave (the routed join's kick of it) is held.
        let sessionA = RoutedLeaveHold.gates.fresh { SessionID("s-a-leave-\($0)") }
        let leaveA = RoutedLeaveHold.gates.gate(sessionA)
        defer { leaveA.open() }
        try await h.container.keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c-a"), sessionID: sessionA)

        let (session, connection, gate) = await h.connect()
        defer { gate.open() }
        let admissionsBefore = await adapter.inTurnAdmissionCountForTesting
        let routedEnded = TestGate()
        defer { routedEnded.open() }
        let routed = try h.startRoutedJoin(session, ended: routedEnded)
        defer { routed.cancel() }
        guard await leaveA.waitForArrivals(1) else {
            Issue.record("the routed join never kicked A")
            return
        }
        // The direct join arrives later and waits for the kick's leave (#943): A's entry is
        // gone, its OnLeave not yet appended.
        let keeper = h.container.keeper
        let direct = Task { () -> (any Error)? in
            do {
                try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c-direct"), sessionID: SessionID("s-direct"))
                return nil
            } catch {
                return error
            }
        }
        defer { direct.cancel() }
        guard await withinHangBound({ await keeper.waitForLeaveEndWaitersForTesting(PlayerID("p1"), count: 1) }) else {
            Issue.record("the direct join never waited for the kick's leave")
            return
        }

        // The kick returns: a later join arrived, so the routed join is fenced out, and the
        // direct join joins after A's OnLeave.
        // A is held in its OnLeave resolver: the parked joins haven't joined yet.
        #expect(await keeper.currentState().joins == ["c-a"], "a join got in during A's OnLeave")
        leaveA.open()
        let directEnded = EventLog()
        Task {
            _ = await direct.value
            directEnded.append("ended")
        }
        guard await directEnded.waitFor("ended") else {
            Issue.record("the direct join didn't end after the kick")
            return
        }
        let directError = await direct.value
        #expect(directError == nil, "the direct join threw \(String(describing: directError))")
        await h.expectSupersededAnswer(connection, joins: ["c-a", "c-direct"])
        #expect(gate.arrivalCount == 0, "the routed join reached its OnJoin resolvers")
        #expect(await adapter.inTurnAdmissionCountForTesting == admissionsBefore, "the routed join was admitted")
        let bookkeeping = await adapter.joinBookkeepingForTesting(session)
        #expect(bookkeeping.expectedAdmission == false && bookkeeping.memberJoinAttempt == false, "left behind: \(bookkeeping)")
    }

    @Test("A routed join parked behind its player's leave in flight, and superseded by a later join parked behind it too, gets the 4017 close, never reaches OnJoin or the admission, and leaves no join bookkeeping (#943)")
    func parkedLoserClosesWith4017() async throws {
        let h = try await RoutedSupersedeHarness.make(joinBudget: .zero)
        let adapter = h.container.transportAdapter
        let keeper = h.container.keeper
        let player = PlayerID("p1")
        // A holds the player; its own leave is held in OnLeave's resolver.
        let sessionA = RoutedLeaveHold.gates.fresh { SessionID("s-a-leave-\($0)") }
        let leaveA = RoutedLeaveHold.gates.gate(sessionA)
        defer { leaveA.open() }
        try await keeper.join(playerID: player, clientID: ClientID("c-a"), sessionID: sessionA)
        let leaving = Task { try await keeper.leave(playerID: player, clientID: ClientID("c-a"), sessionID: sessionA) }
        guard await leaveA.waitForArrivals(1) else {
            Issue.record("A's leave never reached its OnLeave resolver")
            return
        }

        // The routed join parks behind A's leave.
        let (session, connection, gate) = await h.connect()
        defer { gate.open() }
        let admissionsBefore = await adapter.inTurnAdmissionCountForTesting
        let routedEnded = TestGate()
        defer { routedEnded.open() }
        let routed = try h.startRoutedJoin(session, ended: routedEnded)
        defer { routed.cancel() }
        guard await withinHangBound({ await keeper.waitForLeaveEndWaitersForTesting(player, count: 1) }) else {
            Issue.record("the routed join never parked behind A's leave")
            return
        }
        // A later direct join parks behind it: the latest arrival.
        let direct = Task { () -> (any Error)? in
            do {
                try await keeper.join(playerID: player, clientID: ClientID("c-direct"), sessionID: SessionID("s-direct"))
                return nil
            } catch {
                return error
            }
        }
        defer { direct.cancel() }
        guard await withinHangBound({ await keeper.waitForLeaveEndWaitersForTesting(player, count: 2) }) else {
            Issue.record("the direct join never parked behind A's leave")
            return
        }

        // A's leave ends: both resume; the routed join is fenced out, and the direct one joins.
        // A is held in its OnLeave resolver: the parked joins haven't joined yet.
        #expect(await keeper.currentState().joins == ["c-a"], "a join got in during A's OnLeave")
        leaveA.open()
        // A task's value can't be bounded with a task group: bound it on an event its end
        // appends.
        let leaveEnded = EventLog()
        Task {
            _ = try? await leaving.value
            leaveEnded.append("ended")
        }
        guard await leaveEnded.waitFor("ended") else {
            Issue.record("A's leave didn't end after its release")
            return
        }
        try await leaving.value
        let directEnded = EventLog()
        Task {
            _ = await direct.value
            directEnded.append("ended")
        }
        guard await directEnded.waitFor("ended") else {
            Issue.record("the direct join didn't end after A's leave")
            return
        }
        let directError = await direct.value
        #expect(directError == nil, "the direct join threw \(String(describing: directError))")
        await h.expectSupersededAnswer(connection, joins: ["c-a", "c-direct"])
        #expect(gate.arrivalCount == 0, "the routed join reached its OnJoin resolvers")
        #expect(await adapter.inTurnAdmissionCountForTesting == admissionsBefore, "the routed join was admitted")
        let bookkeeping = await adapter.joinBookkeepingForTesting(session)
        #expect(bookkeeping.expectedAdmission == false && bookkeeping.memberJoinAttempt == false, "left behind: \(bookkeeping)")
    }
}

/// The same land served by a standalone adapter (the legacy join, no router): the transport's
/// delegate is the adapter, which answers the join itself (`finalizeJoinRequest`).
private struct StandaloneSupersedeHarness {
    let transport: WebSocketTransport
    let keeper: LandKeeper<RoutedSupersedeState>
    let adapter: TransportAdapter<RoutedSupersedeState>

    static func make() async -> StandaloneSupersedeHarness {
        let transport = WebSocketTransport()
        let keeper = LandKeeper<RoutedSupersedeState>(definition: RoutedSupersedeHarness.definition(), initialState: RoutedSupersedeState())
        let adapter = TransportAdapter<RoutedSupersedeState>(
            keeper: keeper,
            transport: transport,
            landID: "routed-supersede",
            enableLegacyJoin: true
        )
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        return StandaloneSupersedeHarness(transport: transport, keeper: keeper, adapter: adapter)
    }

    /// A connected session with a fresh key, and the gate its OnJoin resolver holds on.
    func connect() async -> (SessionID, RoutedSupersedeConnection, TestGate) {
        let session = RoutedSupersedeHold.gates.fresh { SessionID("s-standalone-\($0)") }
        let connection = RoutedSupersedeConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return (session, connection, RoutedSupersedeHold.gates.gate(session))
    }

    /// The adapter's join of p1, sent from its own task; `ended` is arrived at once the
    /// adapter's handling returns.
    func startJoin(_ session: SessionID, ended: TestGate) throws -> Task<Void, Never> {
        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1", landID: "routed-supersede", playerID: "p1", deviceID: nil, metadata: nil
        ))
        let transport = self.transport
        return Task {
            await transport.handleIncomingMessage(sessionID: session, data: join)
            await ended.arrive()
        }
    }

    /// A direct keeper join of p1 from its own task, reported through a gate (as the routed
    /// harness's `directJoin`). True when it ended without an error.
    func directJoin() async -> Bool {
        let keeper = self.keeper
        let ended = TestGate()
        defer { ended.open() }
        let direct = Task { () -> (any Error)? in
            defer { Task { await ended.arrive() } }
            do {
                try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c-direct"), sessionID: SessionID("s-direct"))
                return nil
            } catch {
                return error
            }
        }
        guard await ended.waitForArrivals(1) else {
            Issue.record("the direct join didn't end while the adapter's join was held")
            return false
        }
        let error = await direct.value
        #expect(error == nil, "the direct join threw \(String(describing: error))")
        return error == nil
    }

    /// The session's whole log is the superseded answer, and the direct join keeps the player.
    /// Once the adapter's join handler has returned (`ended`) and its writer is idle, a probe
    /// frame is sent to the session: behind a close marker it is dropped and the 4017 close
    /// comes; on a session left open it arrives. Either ends the wait, without timing.
    func expectSupersededAnswer(_ session: SessionID, _ connection: RoutedSupersedeConnection, ended: TestGate, joins: [String] = ["c-direct"], sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(await ended.waitForArrivals(1), "the adapter's join handler didn't return", sourceLocation: sourceLocation)
        await adapter.waitForOutboundIdleForTesting()
        await transport.sendSessionFrames([SessionFrame(data: Data("probe".utf8), sessionID: session, connectionGeneration: nil, kind: .text)])
        let settled = await withinHangBound { await connection.waitFor { $0.contains { $0.hasPrefix("close:") || $0 == "frame" } } }
        #expect(settled, "neither the close nor the probe reached the session", sourceLocation: sourceLocation)
        let events = await connection.events
        #expect(events == supersededAnswer, "\(events)", sourceLocation: sourceLocation)
        #expect(await keeper.currentState().joins == joins, sourceLocation: sourceLocation)
    }
}

@Suite("A standalone adapter's legacy join superseded by a newer join answers with the 4017 close (#947)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct StandaloneJoinSupersededTests {
    @Test("Superseded during its OnJoin resolvers: JOIN_DENIED is the session's last frame, with the 4017 close behind it")
    func supersededAtOnJoin() async throws {
        let h = await StandaloneSupersedeHarness.make()
        let (session, connection, gate) = await h.connect()
        defer { gate.open() }
        let ended = TestGate()
        defer { ended.open() }
        let join = try h.startJoin(session, ended: ended)
        defer { join.cancel() }
        guard await gate.waitForArrivals(1) else {
            Issue.record("the adapter's join never reached its OnJoin resolver")
            return
        }
        guard await h.directJoin() else { return }

        gate.open()
        await h.expectSupersededAnswer(session, connection, ended: ended)
    }

    @Test("Fenced out at its kick (J2c) by a later join: JOIN_DENIED is the session's last frame, with the 4017 close behind it")
    func supersededAtTheKick() async throws {
        let h = await StandaloneSupersedeHarness.make()
        // A holds the player; its OnLeave (the adapter's join's kick of it) is held.
        let sessionA = RoutedLeaveHold.gates.fresh { SessionID("s-standalone-a-\($0)") }
        let leaveA = RoutedLeaveHold.gates.gate(sessionA)
        defer { leaveA.open() }
        try await h.keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c-a"), sessionID: sessionA)

        let (session, connection, gate) = await h.connect()
        defer { gate.open() }
        let ended = TestGate()
        defer { ended.open() }
        let join = try h.startJoin(session, ended: ended)
        defer { join.cancel() }
        guard await leaveA.waitForArrivals(1) else {
            Issue.record("the adapter's join never kicked A")
            return
        }
        // The direct join arrives later and waits for the kick's leave (#943): A's entry is
        // gone, its OnLeave not yet appended.
        let keeper = h.keeper
        let direct = Task { () -> (any Error)? in
            do {
                try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c-direct"), sessionID: SessionID("s-direct"))
                return nil
            } catch {
                return error
            }
        }
        defer { direct.cancel() }
        guard await withinHangBound({ await keeper.waitForLeaveEndWaitersForTesting(PlayerID("p1"), count: 1) }) else {
            Issue.record("the direct join never waited for the kick's leave")
            return
        }

        // The kick returns: a later join arrived, so the adapter's join is fenced out, and the
        // direct join joins after A's OnLeave.
        // A is held in its OnLeave resolver: the parked join hasn't joined yet.
        #expect(await keeper.currentState().joins == ["c-a"], "a join got in during A's OnLeave")
        leaveA.open()
        let directEnded = EventLog()
        Task {
            _ = await direct.value
            directEnded.append("ended")
        }
        guard await directEnded.waitFor("ended") else {
            Issue.record("the direct join didn't end after the kick")
            return
        }
        let directError = await direct.value
        #expect(directError == nil, "the direct join threw \(String(describing: directError))")
        await h.expectSupersededAnswer(session, connection, ended: ended, joins: ["c-a", "c-direct"])
        #expect(gate.arrivalCount == 0, "the adapter's join reached its OnJoin resolvers")
    }
}
