// Tests/SwiftStateTreeNIOTests/GracefulShutdownTests.swift
//
// NIOLandHost's graceful shutdown (#351). Each bounded step's deadline is a gate the test opens
// (`GateDeadlines`), and the interleavings are forced with hold points and gates, never timing.

import Foundation
import Logging
import NIOCore
import NIOPosix
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

@StateNodeBuilder
private struct ShutdownState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [String] = []
}

/// A gate for the tests here: code under test arrives, the test opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivals += 1
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }

    var arrivalCount: Int {
        lock.lock(); defer { lock.unlock() }
        return arrivals
    }

    func waitForArrivals(_ count: Int) async -> Bool {
        await poll { self.arrivalCount >= count }
    }
}

/// Polls `condition` every 5 ms for up to 10 s; returns its final value.
private func poll(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Each step's deadline passes when its gate opens; a step without a gate never expires.
private struct GateDeadlines: ShutdownDeadlines {
    var gates: [ShutdownStep: Gate] = [:]

    func expire(_ step: ShutdownStep, at deadline: ContinuousClock.Instant) async {
        if let gate = gates[step] {
            await gate.arrive()
        } else {
            // Never: the step runs to its end.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
    }
}

/// What the land's handlers did, in order.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ event: String) { lock.lock(); list.append(event); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    func count(_ event: String) -> Int { all.filter { $0 == event }.count }
}

/// Records frames and the close code.
private actor ShutdownConnection: WebSocketConnection {
    private(set) var frames: [Data] = []
    private(set) var closeCode: UInt16?
    private(set) var closed = false

    func send(_ data: Data) async throws { frames.append(data) }
    func close() async throws { closed = true; closeCode = 1000 }
    func close(with close: SessionClose) async throws { closed = true; closeCode = close.code }

    var errorCodes: [String] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
            .compactMap { if case .error(let payload) = $0.payload { return payload.code } else { return nil } }
    }
}

private let landType = "shutdown-test"

/// A land whose handlers record into `events`; `afterFinalize`, if given, runs in AfterFinalize.
private func makeLand(
    events: Events,
    destroyWhenEmpty: Bool = false,
    afterFinalize: (@Sendable () async -> Void)? = nil
) -> LandDefinition<ShutdownState> {
    Land(landType, using: ShutdownState.self) {
        Rules {
            CanJoin { (_: ShutdownState, session: PlayerSession, _: LandContext) in
                .allow(playerID: PlayerID(session.playerID))
            }
            OnJoin { (state: inout ShutdownState, ctx: LandContext) in
                state.players.append(ctx.playerID.rawValue)
            }
            OnLeave { (state: inout ShutdownState, ctx: LandContext) in
                state.players.removeAll { $0 == ctx.playerID.rawValue }
                events.append("leave:\(ctx.playerID.rawValue)")
            }
        }
        Lifetime {
            // The builder has no `if`: without `destroyWhenEmpty` the delay is past any test.
            DestroyWhenEmpty(after: destroyWhenEmpty ? .milliseconds(1) : .seconds(3600)) { (_: inout ShutdownState, _: LandContext) in
                events.append("destroyWhenEmpty")
            }
            OnFinalize { (_: inout ShutdownState, _: LandContext) in
                events.append("finalize")
            }
            AfterFinalize { (_: ShutdownState, _: LandContext) async in
                events.append("afterFinalize")
                await afterFinalize?()
            }
        }
    }
}

/// A started host with one land type, and that land type's server.
private struct Fixture {
    let host: NIOLandHost
    let server: NIOLandServer<ShutdownState>

    static func make(
        land: LandDefinition<ShutdownState>,
        deadlines: GateDeadlines = GateDeadlines(),
        middlewares: [any HostMiddleware] = [],
        start: Bool = true
    ) async throws -> Fixture {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "127.0.0.1",
            port: 0,
            logger: Logger(label: "shutdown-test"),
            eventLoopThreads: 1,
            middlewares: middlewares
        ))
        try await host.register(
            landType: landType,
            land: land,
            initialState: ShutdownState(),
            webSocketPath: "/game/\(landType)",
            configuration: NIOLandServerConfiguration(
                logger: Logger(label: "shutdown-test"),
                allowAutoCreateOnJoin: true,
                transportEncoding: .json
            )
        )
        await host.setShutdownDeadlinesForTesting(deadlines)
        if start { try await host.start() }
        let server = try #require(await host.shutdownParticipantsForTesting.first as? NIOLandServer<ShutdownState>)
        return Fixture(host: host, server: server)
    }

    var landID: LandID { LandID(landType: landType, instanceId: "one") }

    func connect(_ session: SessionID) async -> ShutdownConnection {
        let connection = ShutdownConnection()
        await server.transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return connection
    }

    func joinFrame(player: String) throws -> Data {
        try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-\(player)", landType: landType, landInstanceId: "one",
            playerID: player, deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        ))
    }

    /// Connects a session and joins `player` to the land, waiting until the land has it.
    @discardableResult
    func join(_ player: String) async throws -> (SessionID, ShutdownConnection) {
        let session = SessionID("s-\(player)")
        let connection = await connect(session)
        let frame = try joinFrame(player: player)
        let router = server.landRouter
        Task { await router.onMessage(frame, from: session) }
        #expect(await poll { await players().contains(player) }, "\(player) joined")
        return (session, connection)
    }

    func keeper() async throws -> LandKeeper<ShutdownState> {
        try #require(await server.landManager.getLand(landID: landID)).keeper
    }

    func players() async -> [String] {
        guard let container = await server.landManager.getLand(landID: landID) else { return [] }
        return await container.keeper.currentState().players
    }

    func summary() async throws -> HostShutdownSummary {
        try #require(await host.lastShutdownSummary)
    }
}

/// A middleware whose `onShutdown` records, and optionally throws or waits on a gate.
private struct ProbeMiddleware: HostMiddleware {
    let events: Events
    let name: String
    var throwsOnShutdown = false
    var shutdownGate: Gate?
    var startGate: Gate?

    func onStart(context: HostContext) async throws -> Task<Void, Never>? {
        await startGate?.arrive()
        events.append("\(name):start")
        return nil
    }

    func onShutdown(context: HostContext) async throws {
        events.append("\(name):shutdown")
        await shutdownGate?.arrive()
        if throwsOnShutdown { throw ProbeError() }
    }
}

private struct ProbeError: Error {}

@Suite("Shutdown budget (#351, decision C2a)")
struct ShutdownBudgetTests {
    @Test("the default 8 s: steps 1–2 get 2 s, the leaves end at 4 s, the destroy keeps a 4 s floor")
    func defaultSplit() {
        let start = ContinuousClock.now
        let budget = ShutdownBudget(total: .seconds(8), start: start)
        #expect(budget.deregisterDeadline == start + .milliseconds(1750))
        #expect(budget.stopAcceptingDeadline(startedAt: start + .milliseconds(100)) == start + .seconds(2))
        #expect(budget.leavesDeadline == start + .seconds(4))
        // Step 4 started on time: its deadline is the total's end.
        #expect(budget.destroyDeadline(startedAt: start + .seconds(4)) == start + .seconds(8))
    }

    @Test("a late step still gets its minimum: step 2 its 250 ms, the destroy its whole floor")
    func floorsHold() {
        let start = ContinuousClock.now
        let budget = ShutdownBudget(total: .seconds(8), start: start)
        // Step 1 overran (a stuck middleware cut at its deadline, then slack).
        #expect(budget.stopAcceptingDeadline(startedAt: start + .seconds(3)) == start + .milliseconds(3250))
        // Step 4 started past the total: it still gets the floor from its own start.
        #expect(budget.destroyDeadline(startedAt: start + .seconds(7)) == start + .seconds(11))
    }

    @Test("a short total keeps the same shares: 1 s gives 250 ms early, a 500 ms floor")
    func shortTotal() {
        let start = ContinuousClock.now
        let budget = ShutdownBudget(total: .seconds(1), start: start)
        #expect(budget.deregisterDeadline == start)
        #expect(budget.leavesDeadline == start + .milliseconds(500))
        #expect(budget.destroyDeadline(startedAt: start + .milliseconds(500)) == start + .seconds(1))
    }
}

@Suite("NIOLandHost graceful shutdown (#351)", .serialized, .timeLimit(.minutes(1)))
struct GracefulShutdownTests {
    @Test("shutdown closes every session with 1001 after its leave, then destroys the land through the normal path")
    func leavesThenDestroy() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        let (_, c1) = try await f.join("p1")
        let (_, c2) = try await f.join("p2")
        let keeper = try await f.keeper()

        try await f.host.shutdown()

        let all = events.all
        #expect(Set(all.prefix(2)) == ["leave:p1", "leave:p2"], "both leaves ran first: \(all)")
        // The destroy handlers in their order (onDestroyWhenEmpty runs at every destruction).
        #expect(Array(all.dropFirst(2)) == ["destroyWhenEmpty", "finalize", "afterFinalize"], "\(all)")
        #expect(keeper.destructionCause == .forceShutdown)
        #expect(await c1.closeCode == 1001)
        #expect(await c2.closeCode == 1001)
        let summary = try await f.summary()
        #expect(summary.leaves.leaves == 2)
        #expect(summary.leaves.leavesFinished == 2)
        #expect(summary.leaves.sessionsClosed == 2)
        #expect(summary.landsDestroyed == 1)
        #expect(summary.landsAbandoned.isEmpty)
        #expect(summary.timedOutSteps.isEmpty)
        #expect(await f.server.landManager.getLand(landID: f.landID) == nil, "removed by its own epoch")
    }

    @Test("the leaves are awaited: a held leave keeps the shutdown in its sessions step, and both OnLeaves run before OnFinalize")
    func leavesAwaited() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        try await f.join("p2")
        let keeper = try await f.keeper()
        let leaveGate = Gate()
        await keeper.installHolds { point in
            if point == .leave, leaveGate.arrivalCount == 0 { await leaveGate.arrive() }
        }

        let shutdown = Task { try await f.host.shutdown() }
        #expect(await leaveGate.waitForArrivals(1), "the shutdown reached the first leave")
        // No deadline is opened: a shutdown that didn't await the leaves would destroy the land
        // now, and the held leave would then find no player and skip its OnLeave.
        leaveGate.open()
        try await shutdown.value

        let all = events.all
        #expect(Set(all.prefix(2)) == ["leave:p1", "leave:p2"], "\(all)")
        #expect(Array(all.dropFirst(2)) == ["destroyWhenEmpty", "finalize", "afterFinalize"], "\(all)")
        #expect(try await f.summary().leaves.leavesCut == 0)
    }

    @Test("at the sessions step's deadline the queued leaves are cut: the shutdown doesn't wait for them, and their OnLeave doesn't run")
    func leavesCutAtDeadline() async throws {
        let events = Events()
        let leavesDeadline = Gate()
        let f = try await Fixture.make(land: makeLand(events: events), deadlines: GateDeadlines(gates: [.leaves: leavesDeadline]))
        let (_, c1) = try await f.join("p1")
        let (_, c2) = try await f.join("p2")
        let keeper = try await f.keeper()
        let leaveGate = Gate()
        await keeper.installHolds { point in
            if point == .leave, leaveGate.arrivalCount == 0 { await leaveGate.arrive() }
        }

        let shutdown = Task { try await f.host.shutdown() }
        #expect(await leaveGate.waitForArrivals(1), "the first leave is held")
        #expect(await leavesDeadline.waitForArrivals(1), "the sessions step is waiting on its deadline")
        leavesDeadline.open()
        // Returns while the first leave is still held: nothing waits on the cut leaves.
        try await shutdown.value

        let summary = try await f.summary()
        #expect(summary.timedOutSteps == [.leaves])
        #expect(summary.leaves.leaves == 2)
        #expect(summary.leaves.leavesCut == 2)
        #expect(summary.landsDestroyed == 1)
        #expect(events.count("finalize") == 1)
        // Cut sessions are closed by the transport's stop, with 1001 as the others (A1).
        #expect(await c1.closeCode == 1001)
        #expect(await c2.closeCode == 1001)
        leaveGate.open()
        // The held leave resumes after the destruction: the player is gone, so no OnLeave.
        await keeper.waitUntilDrained()
        #expect(events.all.filter { $0.hasPrefix("leave:") }.isEmpty, "\(events.all)")
    }

    @Test("a destroy already in progress when the shutdown starts is joined, not run twice")
    func destroyInProgressJoined() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events, destroyWhenEmpty: true))
        let (session, _) = try await f.join("p1")
        let keeper = try await f.keeper()
        let drainGate = Gate()
        await keeper.installHolds { point in
            if point == .drainStart { await drainGate.arrive() }
        }
        // The player leaves: the land empties and its empty-room timer starts the destruction.
        await f.server.transport.handleDisconnection(sessionID: session)
        #expect(await drainGate.waitForArrivals(1), "the empty-room destruction is held at its start")

        // The shutdown lists the land while its destruction is held; only then is it let go.
        let listed = Gate()
        await f.server.landManager.installHolds { point in
            if point == .shutdownListed { await listed.arrive() }
        }
        let shutdown = Task { try await f.host.shutdown() }
        #expect(await listed.waitForArrivals(1), "the shutdown listed the land mid-destruction")
        listed.open()
        drainGate.open()
        try await shutdown.value

        // Joined: the shutdown returned after the destruction's last handler, which ran once.
        #expect(events.count("afterFinalize") == 1, "\(events.all)")
        #expect(events.count("finalize") == 1, "\(events.all)")
        #expect(keeper.destructionCause == .emptyTimeout)
        #expect(try await f.summary().landsDestroyed == 1)
    }

    @Test("a land detached by removeLand (admin DELETE) and still alive gets its destroy and its save")
    func detachedLandDestroyed() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let keeper = try await f.keeper()
        await f.server.landManager.removeLand(landID: f.landID)
        #expect(await f.server.landManager.getLand(landID: f.landID) == nil)

        try await f.host.shutdown()
        #expect(events.count("afterFinalize") == 1, "\(events.all)")
        #expect(try await f.summary().landsDestroyed == 1)
        withExtendedLifetime(keeper) {}
    }

    @Test("a creation that ignores cancellation doesn't hold the stored lands' destroy")
    func stuckCreationDoesNotHoldStoredLands() async throws {
        let events = Events()
        let destroyDeadline = Gate()
        let f = try await Fixture.make(land: makeLand(events: events), deadlines: GateDeadlines(gates: [.destroy: destroyDeadline]))
        try await f.join("p1")
        // Another land's creation, held at its start: the hold ignores cancellation.
        let creationGate = Gate()
        await f.server.landManager.installHolds { point in
            if point == .creation { await creationGate.arrive() }
        }
        let manager = f.server.landManager
        let creation = Task {
            try? await manager.getOrCreateLand(
                landID: LandID(landType: landType, instanceId: "two"),
                definition: makeLand(events: events),
                initialState: ShutdownState(),
                metadata: [:]
            )
        }
        #expect(await creationGate.waitForArrivals(1), "the creation is held")

        let shutdown = Task { try await f.host.shutdown() }
        // The stored land is destroyed while the creation still hangs.
        #expect(await poll { events.count("afterFinalize") == 1 }, "\(events.all)")
        #expect(await destroyDeadline.waitForArrivals(1))
        destroyDeadline.open()
        try await shutdown.value
        #expect(try await f.summary().landsDestroyed == 1)
        creationGate.open()
        _ = await creation.value
    }

    @Test("a destroy that hangs is abandoned at its deadline: the shutdown returns, and the land's sessions are ended")
    func hangingDestroyAbandoned() async throws {
        let events = Events()
        let finalizeGate = Gate()
        let destroyDeadline = Gate()
        let f = try await Fixture.make(
            land: makeLand(events: events, afterFinalize: { await finalizeGate.arrive() }),
            deadlines: GateDeadlines(gates: [.destroy: destroyDeadline])
        )
        try await f.join("p1")
        let keeper = try await f.keeper()

        let shutdown = Task { try await f.host.shutdown() }
        #expect(await finalizeGate.waitForArrivals(1), "the destroy is hanging in AfterFinalize")
        #expect(await destroyDeadline.waitForArrivals(1))
        destroyDeadline.open()
        try await shutdown.value

        let summary = try await f.summary()
        #expect(summary.timedOutSteps == [.destroy])
        #expect(summary.landsDestroyed == 0)
        #expect(summary.landsAbandoned == [f.landID])
        #expect(summary.abandonedSessionsEnded == 1)
        #expect(await f.host.serverForTesting == nil, "the server stopped")

        // The abandoned handler finishes later: its own callback removes only its own epoch.
        finalizeGate.open()
        await keeper.waitUntilDrained()
        #expect(await poll { await f.server.landManager.getLand(landID: f.landID) == nil })
    }

    @Test("a throwing and a hanging middleware don't stop the rest: every land still gets its destroy and its save")
    func middlewaresBoundedAndErrorsCollected() async throws {
        let events = Events()
        let hang = Gate()
        let deregisterDeadline = Gate()
        let f = try await Fixture.make(
            land: makeLand(events: events),
            deadlines: GateDeadlines(gates: [.deregister: deregisterDeadline]),
            middlewares: [
                ProbeMiddleware(events: events, name: "hangs", shutdownGate: hang),
                ProbeMiddleware(events: events, name: "throws", throwsOnShutdown: true),
            ]
        )
        try await f.join("p1")

        let shutdown = Task { try await f.host.shutdown() }
        // Reverse order: "throws" runs first, then "hangs" waits.
        #expect(await hang.waitForArrivals(1))
        #expect(await deregisterDeadline.waitForArrivals(1))
        deregisterDeadline.open()
        try await shutdown.value

        let summary = try await f.summary()
        #expect(summary.timedOutSteps == [.deregister])
        #expect(summary.errors.count == 1)
        #expect(summary.errors.first?.contains("ProbeMiddleware") == true)
        // The later steps did more than start: the leave and the destroy completed.
        #expect(events.count("leave:p1") == 1)
        #expect(events.count("finalize") == 1)
        #expect(events.count("afterFinalize") == 1)
        #expect(summary.landsDestroyed == 1)
        hang.open()
    }

    @Test("two concurrent shutdowns run the steps once and both return after them")
    func concurrentShutdownsJoin() async throws {
        let events = Events()
        let gate = Gate()
        let f = try await Fixture.make(
            land: makeLand(events: events),
            middlewares: [ProbeMiddleware(events: events, name: "m", shutdownGate: gate)]
        )
        let first = Task { try await f.host.shutdown() }
        #expect(await gate.waitForArrivals(1))
        let second = Task { try await f.host.shutdown() }
        gate.open()
        try await first.value
        try await second.value
        #expect(events.count("m:shutdown") == 1)
        #expect(await f.host.lifecyclePhaseForTesting == .stopped)
    }

    @Test("a shutdown during the start runs after the start")
    func shutdownDuringStart() async throws {
        let events = Events()
        let startGate = Gate()
        let f = try await Fixture.make(
            land: makeLand(events: events),
            middlewares: [ProbeMiddleware(events: events, name: "m", startGate: startGate)],
            start: false
        )
        let start = Task { try await f.host.start() }
        #expect(await startGate.waitForArrivals(1), "the start is held in a middleware's onStart")
        let shutdown = Task { try await f.host.shutdown() }
        #expect(await poll { await f.host.lifecyclePhaseForTesting == .stopping })
        startGate.open()
        try await shutdown.value
        _ = await start.result
        #expect(events.all == ["m:start", "m:shutdown"], "\(events.all)")
        #expect(await f.host.serverForTesting == nil, "the server the start bound was shut down")
        // A stopped host isn't started again: run() returns at once without serving.
        try await f.host.run()
        #expect(await f.host.serverForTesting == nil)
        #expect(await f.host.lifecyclePhaseForTesting == .stopped)
    }

    @Test("A shutdown before any start: a later run() returns at once without serving or throwing")
    func shutdownBeforeStart() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events), start: false)
        try await f.host.shutdown()
        try await f.host.run()
        #expect(await f.host.serverForTesting == nil)
        #expect(await f.host.lifecyclePhaseForTesting == .stopped)
    }

    @Test("run() returns only after the shutdown finished, whether it was cancelled or shut down from elsewhere")
    func runAwaitsShutdown() async throws {
        for cancel in [true, false] {
            let events = Events()
            let f = try await Fixture.make(land: makeLand(events: events), start: false)
            let run = Task { try await f.host.run() }
            #expect(await poll { await f.host.lifecyclePhaseForTesting == .running })
            try await f.join("p1")
            if cancel {
                run.cancel()
            } else {
                try await f.host.shutdown()
            }
            try await run.value
            // run() returned: the land was destroyed by then, not afterwards.
            #expect(events.count("afterFinalize") == 1, "cancel=\(cancel): \(events.all)")
            #expect(await f.host.lifecyclePhaseForTesting == .stopped)
        }
    }

    @Test("an upgrade whose auth finishes after the shutdown completes nothing on the shut-down loop")
    func lateAuthDropped() async throws {
        let authGate = Gate()
        let validator = GatedValidator(gate: authGate)
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "127.0.0.1", port: 0, logger: Logger(label: "shutdown-test"), eventLoopThreads: 1
        ))
        try await host.register(
            landType: landType,
            land: makeLand(events: Events()),
            initialState: ShutdownState(),
            webSocketPath: "/game/\(landType)",
            configuration: NIOLandServerConfiguration(
                logger: Logger(label: "shutdown-test"),
                jwtValidator: validator,
                transportEncoding: .json
            )
        )
        try await host.start()
        let server = try #require(await host.serverForTesting)
        let port = try #require(await server.localAddress?.port)

        // A raw WebSocket upgrade with a token: its auth waits on the gate.
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await ClientBootstrap(group: clientGroup)
            .connect(host: "127.0.0.1", port: port).get()
        var request = client.allocator.buffer(capacity: 256)
        request.writeString(
            "GET /game/\(landType)?token=t HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        try await client.writeAndFlush(request).get()
        #expect(await authGate.waitForArrivals(1), "the upgrade is waiting for its auth")

        try await host.shutdown()
        // The auth finishes after the server stopped: the fence drops its completion.
        authGate.open()
        #expect(await poll { await server.stopFenceDropped >= 1 }, "the late auth was dropped")
        _ = try? await client.close()
        try await clientGroup.shutdownGracefully()
    }
}

/// A token validator that waits on a gate.
private struct GatedValidator: JWTAuthValidator {
    let gate: Gate
    func validate(token: String) async throws -> AuthenticatedInfo {
        await gate.arrive()
        return AuthenticatedInfo(playerID: "p-auth")
    }
}
