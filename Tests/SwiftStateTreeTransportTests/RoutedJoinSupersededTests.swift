// Tests/SwiftStateTreeTransportTests/RoutedJoinSupersededTests.swift
//
// A routed join whose keeper entry is replaced while its OnJoin resolvers run fails with
// `JoinError.superseded` (#860). The router answers it like the flip-stage supersede (#861): the
// `JOIN_DENIED` error is the session's last frame, with the 4017 `superseded` close behind it, so
// the client doesn't rejoin into a kick loop. That holds whoever answers: the join's handler, or
// the join budget's timer that the handler left the answer to. Hosted joins of one player are
// serialized by the adapter's membership queue, so here a direct keeper caller makes the newer
// join.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
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

    static func make(joinBudget: Duration? = nil) async throws -> RoutedSupersedeHarness {
        let definition = Land("routed-supersede", using: RoutedSupersedeState.self) {
            Rules {
                OnJoin(resolvers: RoutedSupersedeResolver.self) { state, _, ctx in
                    state.joins.append(ctx.clientID.rawValue)
                }
            }
        }
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
    /// (nothing else sent, nothing after the close) and that the direct join keeps the player.
    func expectSupersededAnswer(_ connection: RoutedSupersedeConnection, sourceLocation: SourceLocation = #_sourceLocation) async {
        let closed = await withinHangBound { await connection.waitFor { $0.contains { $0.hasPrefix("close:") } } }
        #expect(closed, "the session wasn't closed", sourceLocation: sourceLocation)
        #expect(await connection.events == supersededAnswer, sourceLocation: sourceLocation)
        #expect(await container.keeper.currentState().joins == ["c-direct"], sourceLocation: sourceLocation)
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
}
