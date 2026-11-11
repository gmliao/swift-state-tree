// Tests/SwiftStateTreeNIOTests/GracefulShutdownTests.swift
//
// NIOLandHost's graceful shutdown (#351). Each bounded step's deadline is a gate the test opens
// (`GateDeadlines`), and the interleavings are forced with hold points and gates, never timing.

import Foundation
import Logging
import NIOCore
import NIOHTTP1
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

/// A wait for an event that never comes fails after this. A hang guard, not a timing
/// assumption: each wait returns as soon as its event happens.
private let hangBound: Duration = .seconds(60)

/// A gate for the tests here: code under test arrives, the test opens it.
private final class Gate: @unchecked Sendable {
    private struct ArrivalWaiter {
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [Int: ArrivalWaiter] = [:]
    private var nextWaiterID = 0

    func arrive() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivals += 1
            let reached = takeReachedArrivalWaiters()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
            reached.forEach { $0.resume(returning: true) }
        }
    }

    /// Under the lock: the arrival waiters `arrivals` has reached, removed.
    private func takeReachedArrivalWaiters() -> [CheckedContinuation<Bool, Never>] {
        let ids = arrivalWaiters.filter { $0.value.count <= arrivals }.map(\.key)
        return ids.compactMap { arrivalWaiters.removeValue(forKey: $0)?.continuation }
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

    /// Waits until `count` arrivals happened; resumed by the arrival itself, not by polling.
    /// `false` after `hangBound`, when the code never arrives.
    func waitForArrivals(_ count: Int) async -> Bool {
        let id = lock.withLock { () -> Int in
            defer { nextWaiterID += 1 }
            return nextWaiterID
        }
        let hangGuard = Task { [weak self] in
            try? await safeTaskSleep(for: hangBound)
            self?.expireArrivalWaiter(id)
        }
        defer { hangGuard.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            guard arrivals < count else {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            arrivalWaiters[id] = ArrivalWaiter(count: count, continuation: continuation)
            lock.unlock()
        }
    }

    private func expireArrivalWaiter(_ id: Int) {
        let waiter = lock.withLock { arrivalWaiters.removeValue(forKey: id) }
        waiter?.continuation.resume(returning: false)
    }
}

/// Counts arrivals per hold point, so a hook can hold only the nth.
private final class ArrivalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [LandManagerHoldPoint: Int] = [:]

    func next(_ point: LandManagerHoldPoint) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[point, default: 0] += 1
        return counts[point]!
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
    /// The deadline each step was given.
    let recorded = RecordedDeadlines()

    func expire(_ step: ShutdownStep, at deadline: ContinuousClock.Instant) async {
        recorded.set(step, deadline)
        if let gate = gates[step] {
            await gate.arrive()
        } else {
            // Never: the step runs to its end.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
    }
}

final class RecordedDeadlines: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [ShutdownStep: ContinuousClock.Instant] = [:]
    func set(_ step: ShutdownStep, _ deadline: ContinuousClock.Instant) { lock.lock(); deadlines[step] = deadline; lock.unlock() }
    subscript(step: ShutdownStep) -> ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return deadlines[step] }
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
private func errorCode(of message: TransportMessage) -> String? {
    if case .error(let payload) = message.payload { return payload.code } else { return nil }
}

private actor ShutdownConnection: WebSocketConnection {
    private struct FrameWaiter {
        let condition: @Sendable ([Data]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var frames: [Data] = []
    private(set) var closeCode: UInt16?
    private(set) var closed = false
    private var frameWaiters: [Int: FrameWaiter] = [:]
    private var nextWaiterID = 0

    func send(_ data: Data) async throws {
        frames.append(data)
        let sent = frames
        for (id, waiter) in frameWaiters where waiter.condition(sent) {
            frameWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: true)
        }
    }

    func close() async throws { closed = true; closeCode = 1000 }
    func close(with close: SessionClose) async throws { closed = true; closeCode = close.code }

    var messages: [TransportMessage] { Self.messages(in: frames) }

    private static func messages(in frames: [Data]) -> [TransportMessage] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
    }

    var errorCodes: [String] { messages.compactMap(errorCode(of:)) }

    /// Waits until the transport messages sent so far meet `condition`; resumed by `send`, not
    /// by polling. `false` after `hangBound`, when the frame never comes.
    func waitUntilFrames(_ condition: @escaping @Sendable ([TransportMessage]) -> Bool) async -> Bool {
        await waitUntilRawFrames { condition(Self.messages(in: $0)) }
    }

    /// Waits until a first-sync state frame was sent: the commit that sends it has run (#390).
    func waitForFirstSync() async -> Bool {
        await waitUntilRawFrames { frames in
            frames.contains { String(decoding: $0, as: UTF8.self).contains("\"firstSync\"") }
        }
    }

    /// `waitUntilFrames` over every frame sent, state frames included.
    func waitUntilRawFrames(_ condition: @escaping @Sendable ([Data]) -> Bool) async -> Bool {
        if condition(frames) { return true }
        let id = nextWaiterID
        nextWaiterID += 1
        let hangGuard = Task { [weak self] in
            try? await safeTaskSleep(for: hangBound)
            await self?.expireWaiter(id)
        }
        defer { hangGuard.cancel() }
        return await withCheckedContinuation { continuation in
            frameWaiters[id] = FrameWaiter(condition: condition, continuation: continuation)
        }
    }

    private func expireWaiter(_ id: Int) {
        frameWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }
}

private let landType = "shutdown-test"

/// A land whose handlers record into `events`; `afterFinalize`, if given, runs in AfterFinalize.
private func makeLand(
    events: Events,
    destroyWhenEmpty: Bool = false,
    afterFinalize: (@Sendable () async -> Void)? = nil,
    finalizePlayers: Events? = nil
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
            OnFinalize { (state: inout ShutdownState, _: LandContext) in
                events.append("finalize")
                // The players still in at the destroy: an instance whose sessions' leaves ran
                // on it has none (#390). Recorded apart, so the handler order above stays as is.
                finalizePlayers?.append(state.players.sorted().joined(separator: ","))
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
        shutdownTimeout: Duration = .seconds(8),
        start: Bool = true
    ) async throws -> Fixture {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "127.0.0.1",
            port: 0,
            logger: Logger(label: "shutdown-test"),
            eventLoopThreads: 1,
            middlewares: middlewares,
            shutdownTimeout: shutdownTimeout
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

    @Test("each step gets its budget's deadline: the sessions step ends by T - T/2, the destroy keeps at least T/2 after it")
    func stepDeadlinesFollowTheBudget() async throws {
        let events = Events()
        let deadlines = GateDeadlines(gates: [.deregister: Gate(), .leaves: Gate(), .destroy: Gate()])
        let f = try await Fixture.make(land: makeLand(events: events), deadlines: deadlines)
        try await f.join("p1")
        try await f.host.shutdown()
        let total = Duration.seconds(8)  // the default `shutdownTimeout`
        let deregister = try #require(deadlines.recorded[.deregister])
        let leaves = try #require(deadlines.recorded[.leaves])
        let destroy = try #require(deadlines.recorded[.destroy])
        // From the same start: deregister at start + min(T/4, 2 s) - 250 ms (stop-accepting's
        // minimum), leaves at start + T - T/2.
        #expect(leaves - deregister == total / 2 - (min(total / 4, .seconds(2)) - .milliseconds(250)))
        #expect(destroy - leaves >= total / 2, "the destroy floor: half the total after the sessions step")
    }

    @Test("a land detached by ID (detachLand) and still alive gets its destroy and its save")
    func detachedLandDestroyed() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let keeper = try await f.keeper()
        await f.server.landManager.detachLand(landID: f.landID)
        #expect(await f.server.landManager.getLand(landID: f.landID) == nil)

        try await f.host.shutdown()
        #expect(events.count("afterFinalize") == 1, "\(events.all)")
        #expect(try await f.summary().landsDestroyed == 1)
        withExtendedLifetime(keeper) {}
    }

    // MARK: - A session goes to the instance it joined (#390)

    @Test("after its ID is detached and stored again, each session's leave runs on the instance it joined (#390)")
    func detachedSessionLeavesOnItsInstance() async throws {
        let events = Events()
        let finalizePlayers = Events()
        let f = try await Fixture.make(land: makeLand(events: events, finalizePlayers: finalizePlayers))
        try await f.join("p1")
        let detachedKeeper = try await f.keeper()
        await f.server.landManager.detachLand(landID: f.landID)
        // A join for the ID creates a new stored instance beside the detached one.
        try await f.join("p2")
        let storedKeeper = try await f.keeper()
        #expect(storedKeeper !== detachedKeeper)

        try await f.host.shutdown()
        #expect(events.count("leave:p1") == 1, "\(events.all)")
        #expect(events.count("leave:p2") == 1, "\(events.all)")
        // Both instances destroyed with no player left: p1 left the detached one, not the new one.
        #expect(finalizePlayers.all == ["", ""], "\(finalizePlayers.all)")
        withExtendedLifetime((detachedKeeper, storedKeeper)) {}
    }

    @Test("after its ID is detached and stored again, a session's sync ack goes to the instance it joined (#390)")
    func detachedSessionAckReachesItsInstance() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        let (p1, p1Connection) = try await f.join("p1")
        // `join` returns once the land has p1; its first sync commits after.
        #expect(await p1Connection.waitForFirstSync(), "p1's first sync was sent")
        let detached = try #require(await f.server.landManager.getLand(landID: f.landID))
        await f.server.landManager.detachLand(landID: f.landID)
        try await f.join("p2")
        let stored = try #require(await f.server.landManager.getLand(landID: f.landID))
        // p1's first view is the newest entry of its lag FIFO on the instance it joined.
        let seq = try #require(await detached.transportAdapter.syncLagLastCommittedSeqForTesting(p1))

        await f.server.landRouter.onMessage(SyncAckFrame.encode(seq: seq, binary: false), from: p1)
        // The detached instance applied it: its FIFO for p1 is empty.
        #expect(await detached.transportAdapter.syncLagLastCommittedSeqForTesting(p1) == nil, "the joined instance got the ack")
        #expect(await detached.transportAdapter.syncLagDroppedAcks == 0)
        // The new instance never saw p1's session: an ack routed there is dropped and counted.
        #expect(await stored.transportAdapter.syncLagDroppedAcks == 0)
        try await f.host.shutdown()
        withExtendedLifetime(detached) {}
    }

    @Test("a session whose instance was destroyed gets \"land no longer exists\", is unbound, and can join again (#390)")
    func endedInstanceSessionRejoins() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        let (p1, connection) = try await f.join("p1")
        // Held for the whole test: the manager no longer having the epoch is what says the
        // instance ended, not its adapter going away.
        let old = try #require(await f.server.landManager.getLand(landID: f.landID))
        await f.server.landManager.detachLand(landID: f.landID)
        await old.keeper.forceShutdown()
        // `forceShutdown` awaits the destroy through `onLandDestroyed`, which drops the epoch.
        #expect(await f.server.landManager.isLive(landID: f.landID, epoch: old.epoch) == false, "its destroy dropped the instance")
        #expect(await f.server.landRouter.isBound(sessionID: p1), "still bound until it sends")

        let action = try JSONEncoder().encode(TransportMessage.action(
            requestID: "a-1",
            action: ActionEnvelope(typeIdentifier: "Probe", payload: AnyCodable("x"))
        ))
        await f.server.landRouter.onMessage(action, from: p1)
        // The error goes out through the session's send queue, which drains on its own task.
        #expect(await connection.waitUntilFrames { $0.contains { errorCode(of: $0) == ErrorCode.joinRoomNotFound.rawValue } }, "JOIN_ROOM_NOT_FOUND sent")
        #expect(await f.server.landRouter.isBound(sessionID: p1) == false)

        // A join on the same connection is a join, not "already joined".
        await f.server.landRouter.onMessage(try f.joinFrame(player: "p1"), from: p1)
        #expect(await connection.waitUntilFrames { $0.filter { $0.kind == .joinResponse }.count == 2 }, "a second JoinResponse")
        #expect(await f.players().contains("p1"), "rejoined a new instance")
        #expect(await connection.errorCodes.contains(ErrorCode.joinAlreadyJoined.rawValue) == false)
        withExtendedLifetime(old) {}
        try await f.host.shutdown()
    }

    @Test("a forward that finds its instance ended clears only that binding: a rebind during it survives (#390)")
    func endedInstanceClearKeepsNewerBinding() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        let (p1, connection) = try await f.join("p1")
        let old = try #require(await f.server.landManager.getLand(landID: f.landID))
        await f.server.landManager.detachLand(landID: f.landID)
        await old.keeper.forceShutdown()
        let router = f.server.landRouter

        let gate = Gate()
        let registry = HoldRegistry<LandRouterHoldPoint>().on(.boundInstanceEnded, arrival: 1) { await gate.arrive() }
        await router.installHolds(registry.hook)
        let first = try JSONEncoder().encode(TransportMessage.action(
            requestID: "a-held", action: ActionEnvelope(typeIdentifier: "Probe", payload: AnyCodable("x"))
        ))
        let held = Task { await router.onMessage(first, from: p1) }
        #expect(await gate.waitForArrivals(1), "the first forward found the instance ended")

        // Meanwhile a second frame clears the binding, and the session joins a new instance.
        let second = try JSONEncoder().encode(TransportMessage.action(
            requestID: "a-second", action: ActionEnvelope(typeIdentifier: "Probe", payload: AnyCodable("x"))
        ))
        await router.onMessage(second, from: p1)
        #expect(await router.isBound(sessionID: p1) == false)
        await router.onMessage(try f.joinFrame(player: "p1"), from: p1)
        #expect(await connection.waitUntilFrames { $0.filter { $0.kind == .joinResponse }.count == 2 }, "rejoined")
        #expect(await router.isBound(sessionID: p1))

        gate.open()
        await held.value
        // The held forward's epoch is the old one: it leaves the new binding alone.
        #expect(await router.isBound(sessionID: p1), "the newer binding survives")
        #expect(await f.players().contains("p1"))
        withExtendedLifetime(old) {}
        try await f.host.shutdown()
    }

    @Test("the router holds a session's instance weakly: a destroyed instance's adapter goes while the session is still bound (#390)")
    func boundSessionDoesNotRetainItsInstance() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        let (p1, _) = try await f.join("p1")
        weak var oldAdapter: TransportAdapter<ShutdownState>?
        do {
            // Scoped: the test holds the old instance only weakly once it is destroyed.
            let container = try #require(await f.server.landManager.getLand(landID: f.landID))
            oldAdapter = container.transportAdapter
            await f.server.landManager.detachLand(landID: f.landID)
            await container.keeper.forceShutdown()
        }
        #expect(await f.server.landRouter.isBound(sessionID: p1), "bound: nothing has cleared it")
        // wall-clock: a release has no event; the tasks that still hold the adapter end on their own
        #expect(await poll { oldAdapter == nil }, "the destroyed instance's adapter is released")
        try await f.host.shutdown()
    }

    @Test("a creation that ignores cancellation doesn't hold the stored lands' destroy")
    func stuckCreationDoesNotHoldStoredLands() async throws {
        let events = Events()
        let destroyDeadline = Gate()
        let finalized = Gate()
        finalized.open()
        let f = try await Fixture.make(
            land: makeLand(events: events, afterFinalize: { await finalized.arrive() }),
            deadlines: GateDeadlines(gates: [.destroy: destroyDeadline])
        )
        try await f.join("p1")
        // The stored land's destroy is counted only once its `forceShutdown` returns, after
        // AfterFinalize (#508). Held there until the summary is reached, so the step's deadline
        // always opens first; the summary waits for that count.
        let destroyReturn = Gate()
        try await f.keeper().installHolds(
            HoldRegistry<LandKeeperHoldPoint>().on(.forceShutdownReturn) { await destroyReturn.arrive() }.hook
        )
        defer { destroyReturn.open() }
        await f.host.installBeforeShutdownSummaryForTesting { lands in
            destroyReturn.open()
            await lands.waitForFinished(1)
        }
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
        #expect(await finalized.waitForArrivals(1), "\(events.all)")
        #expect(await destroyReturn.waitForArrivals(1), "the destroy is held at its return")
        #expect(await destroyDeadline.waitForArrivals(1))
        destroyDeadline.open()
        try await shutdown.value
        #expect(try await f.summary().landsDestroyed == 1)
        creationGate.open()
        _ = await creation.value
    }

    @Test("a hung destroy holds no other land: a creation that ends during the destroy step gets its destroy")
    func hungDestroyHoldsNoCreation() async throws {
        let events = Events()
        let finalizeGate = Gate()
        let destroyDeadline = Gate()
        let f = try await Fixture.make(
            land: makeLand(events: events, afterFinalize: { await finalizeGate.arrive() }),
            deadlines: GateDeadlines(gates: [.destroy: destroyDeadline])
        )
        try await f.join("p1")
        let keeper = try await f.keeper()
        // Another land's creation, held before its publication.
        let publishGate = Gate()
        await f.server.landManager.installHolds { point in
            if point == .publish { await publishGate.arrive() }
        }
        let lateDestroyed = Gate()
        lateDestroyed.open()
        let manager = f.server.landManager
        let creation = Task {
            try? await manager.getOrCreateLand(
                landID: LandID(landType: landType, instanceId: "two"),
                definition: makeLand(events: Events(), afterFinalize: { await lateDestroyed.arrive() }),
                initialState: ShutdownState(),
                metadata: [:]
            )
        }
        #expect(await publishGate.waitForArrivals(1), "the creation is held")
        // The late land's AfterFinalize runs before its destroy is counted: the summary waits
        // for that count, so the step's deadline opening early can't race it.
        await f.host.installBeforeShutdownSummaryForTesting { lands in await lands.waitForFinished(1) }

        let shutdown = Task { try await f.host.shutdown() }
        #expect(await finalizeGate.waitForArrivals(1), "the stored land's destroy hangs")
        // The creation ends while the stored land's destroy still hangs: its land is destroyed.
        publishGate.open()
        #expect(await lateDestroyed.waitForArrivals(1), "the late land got its destroy")
        #expect(await destroyDeadline.waitForArrivals(1))
        destroyDeadline.open()
        try await shutdown.value

        let summary = try await f.summary()
        #expect(summary.landsDestroyed == 1)
        #expect(summary.landsAbandoned == [f.landID])
        #expect(summary.creationsUnfinished == 0)
        _ = await creation.value
        finalizeGate.open()
        await keeper.waitUntilDrained()
    }

    @Test("a creation that publishes after the listing goes out at once, not behind another creation that hangs")
    func publishedAfterListingNotBehindHungCreation() async throws {
        let events = Events()
        let destroyDeadline = Gate()
        let f = try await Fixture.make(land: makeLand(events: events), deadlines: GateDeadlines(gates: [.destroy: destroyDeadline]))
        try await f.join("p1")
        // A is held before its publication, B (started second) at its start; the shutdown is
        // held right after its listing.
        let aPublish = Gate()
        let bCreation = Gate()
        let listed = Gate()
        let arrivals = ArrivalCounter()
        await f.server.landManager.installHolds { point in
            switch point {
            case .publish where arrivals.next(.publish) == 1: await aPublish.arrive()
            case .creation where arrivals.next(.creation) == 2: await bCreation.arrive()
            case .shutdownListed: await listed.arrive()
            default: break
            }
        }
        let aDestroyed = Gate()
        aDestroyed.open()
        let manager = f.server.landManager
        let creationA = Task {
            try? await manager.getOrCreateLand(
                landID: LandID(landType: landType, instanceId: "a"),
                definition: makeLand(events: Events(), afterFinalize: { await aDestroyed.arrive() }),
                initialState: ShutdownState(),
                metadata: [:]
            )
        }
        #expect(await aPublish.waitForArrivals(1), "A is held before its publication")
        let creationB = Task {
            try? await manager.getOrCreateLand(
                landID: LandID(landType: landType, instanceId: "b"),
                definition: makeLand(events: Events()),
                initialState: ShutdownState(),
                metadata: [:]
            )
        }
        #expect(await bCreation.waitForArrivals(1), "B is held at its start")
        // The stored land and A are counted before the summary is read.
        await f.host.installBeforeShutdownSummaryForTesting { lands in await lands.waitForFinished(2) }

        let shutdown = Task { try await f.host.shutdown() }
        #expect(await listed.waitForArrivals(1), "the listing is taken, without A")
        // A publishes and ends before the second batch looks at the creations.
        aPublish.open()
        #expect(await creationA.value != nil, "A published")
        listed.open()
        // A's land is destroyed while B still hangs.
        #expect(await aDestroyed.waitForArrivals(1), "A's land got its destroy")
        #expect(await destroyDeadline.waitForArrivals(1))
        destroyDeadline.open()
        try await shutdown.value

        let summary = try await f.summary()
        #expect(summary.landsDestroyed == 2)
        #expect(summary.creationsUnfinished == 1)
        bCreation.open()
        _ = await creationB.value
    }

    @Test("abandoned lands are counted per instance: a stored and a detached instance of one ID are two")
    func abandonedCountedPerInstance() async throws {
        let events = Events()
        let finalizeGate = Gate()
        let destroyDeadline = Gate()
        let land = makeLand(events: events, afterFinalize: { await finalizeGate.arrive() })
        let f = try await Fixture.make(land: land, deadlines: GateDeadlines(gates: [.destroy: destroyDeadline]))
        try await f.join("p1")
        let detachedKeeper = try await f.keeper()
        let detachedAdapter = try #require(await f.server.landManager.getLand(landID: f.landID)).transportAdapter
        // Detached and still alive (it has a player), then a new stored instance of the same ID.
        await f.server.landManager.detachLand(landID: f.landID)
        let stored = try await f.server.landManager.getOrCreateLand(
            landID: f.landID, definition: land, initialState: ShutdownState(), metadata: [:]
        )

        let shutdown = Task { try await f.host.shutdown() }
        #expect(await finalizeGate.waitForArrivals(2), "both instances' destroys hang")
        #expect(await destroyDeadline.waitForArrivals(1))
        destroyDeadline.open()
        try await shutdown.value

        let summary = try await f.summary()
        #expect(summary.landsDestroyed == 0)
        #expect(summary.landsAbandoned == [f.landID, f.landID])
        // Each abandoned instance's sessions end by its epoch, the detached one included (#390).
        #expect(summary.abandonedSessionsEnded == 2)
        #expect(await detachedAdapter.teardownTicketEnds == 1, "the detached instance's own adapter")
        #expect(await stored.transportAdapter.teardownTicketEnds == 1)
        finalizeGate.open()
        await detachedKeeper.waitUntilDrained()
        await stored.keeper.waitUntilDrained()
    }

    @Test("the lands are counted at the summary: a destroy that finishes after its step's deadline counts as destroyed")
    func landsCountedAtTheEnd() async throws {
        let events = Events()
        let finalizeGate = Gate()
        let destroyDeadline = Gate()
        let f = try await Fixture.make(
            land: makeLand(events: events, afterFinalize: { await finalizeGate.arrive() }),
            deadlines: GateDeadlines(gates: [.destroy: destroyDeadline])
        )
        try await f.join("p1")
        // Before the summary is read, the abandoned destroy is let finish.
        await f.host.installBeforeShutdownSummaryForTesting { lands in
            finalizeGate.open()
            await lands.waitForFinished(1)
        }

        let shutdown = Task { try await f.host.shutdown() }
        #expect(await finalizeGate.waitForArrivals(1), "the destroy hangs")
        #expect(await destroyDeadline.waitForArrivals(1))
        destroyDeadline.open()
        try await shutdown.value

        let summary = try await f.summary()
        #expect(summary.timedOutSteps == [.destroy])
        #expect(summary.landsDestroyed == 1)
        #expect(summary.landsAbandoned.isEmpty)
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

// MARK: - Land stop (#102)

private let stopAPIKey = "stop-test-key"

/// The admin routes over the fixture's host realm, as `registerAdminRoutes` mounts them.
private func adminRouter(_ f: Fixture) async -> NIOHTTPRouter {
    let routes = NIOAdminRoutes(landRealm: await f.host.realm, adminAuth: NIOAdminAuth(apiKey: stopAPIKey))
    let router = NIOHTTPRouter()
    await routes.registerRoutes(on: router)
    return router
}

private func deleteLand(_ router: NIOHTTPRouter, _ landID: LandID) async throws -> NIOHTTPResponse {
    var headers = HTTPHeaders()
    headers.add(name: "X-API-Key", value: stopAPIKey)
    let request = NIOHTTPRequest(method: .DELETE, uri: "/admin/lands/\(landID.stringValue)", headers: headers, body: nil)
    return try #require(try await router.handle(request))
}

private func stopBody(_ response: NIOHTTPResponse) throws -> StopLandResponseBody {
    let decoded = try JSONDecoder().decode(AdminAPIResponse<StopLandResponseBody>.self, from: try #require(response.body))
    #expect(decoded.success)
    return try #require(decoded.data)
}

/// A stop's result, read after the task that sets it signalled.
private final class StopResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StopLandResult?
    func set(_ value: StopLandResult) { lock.lock(); stored = value; lock.unlock() }
    var value: StopLandResult? { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite("Land stop: the admin DELETE (#102)")
struct LandStopTests {
    @Test("a stop runs its sessions' leaves, closes them with 4014, then destroys the land")
    func stopLeavesClosesAndDestroys() async throws {
        let events = Events()
        let finalizePlayers = Events()
        let f = try await Fixture.make(land: makeLand(events: events, finalizePlayers: finalizePlayers))
        let (_, connection) = try await f.join("p1")
        let keeper = try await f.keeper()

        let response = try await deleteLand(await adminRouter(f), f.landID)
        #expect(response.status == .ok)
        #expect(try stopBody(response) == StopLandResponseBody(stopped: true, timedOut: nil))

        // The leave ran on the instance before its destroy, which then found no players.
        #expect(events.all.filter { !$0.hasPrefix("destroyWhenEmpty") } == ["leave:p1", "finalize", "afterFinalize"])
        #expect(finalizePlayers.all == [""])
        #expect(await connection.closeCode == SessionClose.Code.landStopped)
        #expect(keeper.destructionCause == .forceShutdown)
        #expect(await f.server.listLands().contains(f.landID) == false)
        try await f.host.shutdown()
    }

    @Test("a join after a stop gets a fresh instance; the stopped one sends nothing more")
    func rejoinAfterStopGetsFreshInstance() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        let (_, oldConnection) = try await f.join("p1")
        let old = try #require(await f.server.landManager.getLand(landID: f.landID))
        #expect(await f.server.stopLand(landID: f.landID) == .stopped(timedOut: false))
        let framesAtClose = await oldConnection.frames.count

        let session = SessionID("s-p1-again")
        let connection = await f.connect(session)
        let router = f.server.landRouter
        let frame = try f.joinFrame(player: "p1")
        await router.onMessage(frame, from: session)
        #expect(await connection.waitUntilFrames { $0.contains { $0.kind == .joinResponse } }, "rejoined")
        let fresh = try #require(await f.server.landManager.getLand(landID: f.landID))
        #expect(fresh.epoch != old.epoch)
        #expect(await oldConnection.frames.count == framesAtClose, "nothing from the stopped instance after its close")
        withExtendedLifetime(old) {}
        try await f.host.shutdown()
    }

    @Test("DELETE for an unknown land ID is a 404 and changes nothing")
    func unknownLandIsNotFound() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let unknown = LandID(landType: landType, instanceId: "missing")

        let response = try await deleteLand(await adminRouter(f), unknown)
        #expect(response.status == .notFound)
        #expect(await f.players() == ["p1"])
        #expect(events.all.isEmpty)
        try await f.host.shutdown()
    }

    @Test("two stops of one land share it: one destroy, the same result for both")
    func concurrentStopsShareOneStop() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let detached = Gate()
        await f.server.landManager.installHolds(HoldRegistry<LandManagerHoldPoint>().on(.stopDetached) { await detached.arrive() }.hook)
        let shared = Gate()
        shared.open()
        f.server.stopFlightsForTesting.onSharedForTesting { _ in Task { await shared.arrive() } }

        let server = f.server
        let landID = f.landID
        let first = Task { await server.stopLand(landID: landID) }
        #expect(await detached.waitForArrivals(1), "the first stop detached the land")
        let second = Task { await server.stopLand(landID: landID) }
        #expect(await shared.waitForArrivals(1), "the second stop shares the first")
        detached.open()

        #expect(await first.value == .stopped(timedOut: false))
        #expect(await second.value == .stopped(timedOut: false))
        #expect(events.count("finalize") == 1)
        #expect(detached.arrivalCount == 1, "one detach")
        try await f.host.shutdown()
    }

    @Test("a join that got the instance before its stop doesn't bind to it after the stop's snapshot")
    func joinRacingTheStopIsRefused() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let router = f.server.landRouter
        let joinHeld = Gate()
        let snapshot = Gate()
        snapshot.open()
        await router.installHolds(HoldRegistry<LandRouterHoldPoint>()
            .on(.afterLand) { await joinHeld.arrive() }
            .on(.stopSnapshot) { await snapshot.arrive() }
            .hook)

        let p2 = SessionID("s-p2")
        let connection = await f.connect(p2)
        let frame = try f.joinFrame(player: "p2")
        let join = Task { await router.onMessage(frame, from: p2) }
        #expect(await joinHeld.waitForArrivals(1), "p2's join holds the instance's container")

        let server = f.server
        let landID = f.landID
        let stop = Task { await server.stopLand(landID: landID) }
        #expect(await snapshot.waitForArrivals(1), "the stop took its snapshot")
        joinHeld.open()
        await join.value

        // The error frame goes out through the session's send queue: waited for, not read.
        #expect(await connection.waitUntilFrames { $0.contains { errorCode(of: $0) == ErrorCode.joinDenied.rawValue } })
        #expect(await router.isBound(sessionID: p2) == false)
        #expect(await stop.value == .stopped(timedOut: false))
        try await f.host.shutdown()
    }

    @Test("a join held between the stop's detach and its destroy waits, then gets a fresh instance")
    func joinDuringStopWaitsForTheDestroy() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let old = try #require(await f.server.landManager.getLand(landID: f.landID))
        let detached = Gate()
        let drainWait = Gate()
        drainWait.open()
        await f.server.landManager.installHolds(HoldRegistry<LandManagerHoldPoint>()
            .on(.stopDetached) { await detached.arrive() }
            .on(.drainWait) { await drainWait.arrive() }
            .on(.publish) { events.append("publish") }
            .hook)
        let parked = Gate()
        parked.open()
        await f.server.landManager.onDropWaitParkedForTesting { Task { await parked.arrive() } }

        let server = f.server
        let landID = f.landID
        let stop = Task { await server.stopLand(landID: landID) }
        #expect(await detached.waitForArrivals(1), "the land is detached, not yet destroyed")
        let p2 = SessionID("s-p2")
        let connection = await f.connect(p2)
        let frame = try f.joinFrame(player: "p2")
        let router = f.server.landRouter
        let join = Task { await router.onMessage(frame, from: p2) }
        #expect(await drainWait.waitForArrivals(1), "p2's creation listed the stopping instance")
        // Released only once the creation is parked on the instance's drop: a creation that
        // didn't wait would publish while the stop is still held.
        #expect(await parked.waitForArrivals(1), "p2's creation waits for the stopping instance's drop")
        detached.open()

        #expect(await stop.value == .stopped(timedOut: false))
        await join.value
        #expect(await connection.waitUntilFrames { $0.contains { $0.kind == .joinResponse } }, "p2 joined")
        let fresh = try #require(await f.server.landManager.getLand(landID: f.landID))
        #expect(fresh.epoch != old.epoch)
        // The fresh instance was published only after the stopped one's destroy ended.
        let order = events.all
        let finalized = try #require(order.firstIndex(of: "afterFinalize"))
        let published = try #require(order.firstIndex(of: "publish"))
        #expect(finalized < published, "\(order)")
        withExtendedLifetime(old) {}
        try await f.host.shutdown()
    }

    @Test("a session still joining at the stop is refused and closed with 4014; no join reaches the stopped instance")
    func joiningSessionAtStopIsRefused() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let router = f.server.landRouter
        let admitHeld = Gate()
        await router.installHolds(HoldRegistry<LandRouterHoldPoint>().on(.beforeAdmit) { await admitHeld.arrive() }.hook)

        let p2 = SessionID("s-p2")
        let connection = await f.connect(p2)
        let frame = try f.joinFrame(player: "p2")
        let join = Task { await router.onMessage(frame, from: p2) }
        #expect(await admitHeld.waitForArrivals(1), "p2 is bound and its admission pending")

        #expect(await f.server.stopLand(landID: f.landID) == .stopped(timedOut: false))
        admitHeld.open()
        await join.value

        #expect(await connection.closeCode == SessionClose.Code.landStopped)
        #expect(await connection.messages.contains { $0.kind == .joinResponse } == false)
        #expect(await router.isBound(sessionID: p2) == false)
        #expect(events.all.contains("leave:p1"))
        try await f.host.shutdown()
    }

    @Test("a stop past the host's shutdownTimeout answers timedOut, shared by a second DELETE; it finishes in the background")
    func stopPastItsBoundTimesOut() async throws {
        let events = Events()
        let finalized = Gate()
        finalized.open()
        let f = try await Fixture.make(
            land: makeLand(events: events, afterFinalize: { await finalized.arrive() }),
            shutdownTimeout: .milliseconds(200)
        )
        try await f.join("p1")
        let leavesHeld = Gate()
        defer { leavesHeld.open() }
        await f.server.landRouter.installHolds(HoldRegistry<LandRouterHoldPoint>().on(.stopSnapshot) { await leavesHeld.arrive() }.hook)
        let router = await adminRouter(f)

        // Success is the response itself: the bound passes while the leaves are held.
        let first = try await deleteLand(router, f.landID)
        #expect(first.status == .ok)
        #expect(try stopBody(first) == StopLandResponseBody(stopped: true, timedOut: true))
        #expect(leavesHeld.arrivalCount == 1)
        let second = try await deleteLand(router, f.landID)
        #expect(try stopBody(second) == StopLandResponseBody(stopped: true, timedOut: true))
        #expect(leavesHeld.arrivalCount == 1, "the second DELETE shared the stop")

        leavesHeld.open()
        #expect(await finalized.waitForArrivals(1), "the destroy finished in the background")
        #expect(events.all.contains("leave:p1"))
        #expect(events.count("finalize") == 1)
        try await f.host.shutdown()
    }

    @Test("a cancelled stop request doesn't cancel the stop: the land is destroyed and its ID is free")
    func cancelledRequestStillDestroys() async throws {
        let events = Events()
        let finalized = Gate()
        finalized.open()
        let f = try await Fixture.make(land: makeLand(events: events, afterFinalize: { await finalized.arrive() }))
        try await f.join("p1")
        let old = try #require(await f.server.landManager.getLand(landID: f.landID))
        let leavesHeld = Gate()
        defer { leavesHeld.open() }
        await f.server.landRouter.installHolds(HoldRegistry<LandRouterHoldPoint>().on(.stopSnapshot) { await leavesHeld.arrive() }.hook)

        let server = f.server
        let landID = f.landID
        let request = Task { await server.stopLand(landID: landID) }
        #expect(await leavesHeld.waitForArrivals(1), "the stop's leaves are held")
        request.cancel()
        // The request returns while the stop is still held: its wait ends, not the stop.
        let returned = Gate()
        returned.open()
        let result = StopResultRecorder()
        Task { result.set(await request.value); await returned.arrive() }
        #expect(await returned.waitForArrivals(1), "the cancelled request stops waiting before the stop ends")
        #expect(result.value == .stopped(timedOut: true))

        leavesHeld.open()
        #expect(await finalized.waitForArrivals(1), "the destroy ran")
        #expect(events.all.contains("leave:p1"))
        // The entry was dropped: a join gets a fresh instance at once, not a drain wait (which
        // would outlast the join's wait, `drainWaitTimeout` being 30 s).
        try await f.join("p2")
        let fresh = try #require(await f.server.landManager.getLand(landID: f.landID))
        #expect(fresh.epoch != old.epoch)
        withExtendedLifetime(old) {}
        try await f.host.shutdown()
    }

    @Test("a creation that listed a stopping instance and waits after its drop goes on at once")
    func dropBeforeTheWaitIsSeen() async throws {
        let events = Events()
        let f = try await Fixture.make(land: makeLand(events: events))
        try await f.join("p1")
        let old = try #require(await f.server.landManager.getLand(landID: f.landID))
        // Past the hang guard, and bounded: a missed drop fails the join's wait below, then
        // the creation gives up here and the test ends.
        await f.server.landManager.setDrainWaitTimeout(hangBound * 2)
        let detached = Gate()
        let drainWait = Gate()
        await f.server.landManager.installHolds(HoldRegistry<LandManagerHoldPoint>()
            .on(.stopDetached) { await detached.arrive() }
            .on(.drainWait) { await drainWait.arrive() }
            .hook)

        let server = f.server
        let landID = f.landID
        let stop = Task { await server.stopLand(landID: landID) }
        #expect(await detached.waitForArrivals(1))
        let p2 = SessionID("s-p2")
        let connection = await f.connect(p2)
        let frame = try f.joinFrame(player: "p2")
        let router = f.server.landRouter
        let join = Task { await router.onMessage(frame, from: p2) }
        #expect(await drainWait.waitForArrivals(1), "p2's creation listed the stopping instance")

        // The stop finishes and drops the instance (its destroy awaits the drop) before the
        // creation's wait registers.
        detached.open()
        #expect(await stop.value == .stopped(timedOut: false))
        drainWait.open()
        #expect(await connection.waitUntilFrames { $0.contains { $0.kind == .joinResponse } }, "p2 joined at once")
        await join.value
        let fresh = try #require(await f.server.landManager.getLand(landID: f.landID))
        #expect(fresh.epoch != old.epoch)
        withExtendedLifetime(old) {}
        try await f.host.shutdown()
    }
}
