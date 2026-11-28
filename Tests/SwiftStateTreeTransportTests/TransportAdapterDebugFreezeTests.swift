// Tests/SwiftStateTreeTransportTests/TransportAdapterDebugFreezeTests.swift
//
// TransportAdapter.debugFreeze(): settle cycle, projection from the settle copy, reference
// counting, auto-resume, and syncs deferred while frozen (#79).

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// MARK: - Test land

@StateNodeBuilder
struct DebugFreezeAdapterState: StateNodeProtocol {
    @Sync(.broadcast)
    var headline: String = ""

    @Sync(.broadcast)
    var members: [PlayerID: Bool] = [:]

    @Sync(.perPlayerSlice())
    var scores: [PlayerID: Int] = [:]

    public init() {}
}

@Payload
struct DebugFreezeUpdateAction: ActionPayload {
    typealias Response = DebugFreezeUpdateAck
    let headline: String
    let score: Int
}

@Payload
struct DebugFreezeUpdateAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct DebugFreezeStuckAction: ActionPayload {
    typealias Response = DebugFreezeUpdateAck
    let headline: String
}

/// Gate the stuck resolver waits on; only `stuckResolverTimesOut` uses it.
actor DebugFreezeStuckGate {
    static let shared = DebugFreezeStuckGate()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingCount = 0

    func pass() async {
        guard !isOpen else { return }
        waitingCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@PlainData
struct DebugFreezeStuckResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = DebugFreezeStuckOutput

    func resolve(_ deps: NoServices) async throws -> DebugFreezeStuckOutput {
        await DebugFreezeStuckGate.shared.pass()
        return DebugFreezeStuckOutput(ok: true)
    }
}

@PlainData
struct DebugFreezeStuckOutput: ResolverOutput {
    let ok: Bool
}

/// Tickless land; leaving removes the player from a broadcast map, which requests a
/// broadcast-only sync.
private func makeDefinition() -> LandDefinition<DebugFreezeAdapterState> {
    Land("debug-freeze-adapter", using: DebugFreezeAdapterState.self) {
        Rules {
            OnJoin { state, ctx in
                state.members[ctx.playerID] = true
            }
            OnLeave { state, ctx in
                state.members.removeValue(forKey: ctx.playerID)
            }
            HandleAction(DebugFreezeStuckAction.self, resolvers: { _, _, _ in DebugFreezeStuckResolver() }) {
                state, action, _, _ in
                state.headline = action.headline
                return DebugFreezeUpdateAck(ok: true)
            }
            HandleAction(DebugFreezeUpdateAction.self) {
                state, action, ctx in
                state.headline = action.headline
                state.scores[ctx.playerID] = action.score
                return DebugFreezeUpdateAck(ok: true)
            }
        }
    }
}

// MARK: - Fixture

private actor DebugFreezeRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }

    /// Frames that reach `sessionID` (addressed to it, its player, or everyone).
    func frames(for sessionID: SessionID, playerID: PlayerID) -> [Data] {
        sent.compactMap { entry in
            switch entry.target {
            case .session(let id) where id == sessionID: return entry.data
            case .player(let id) where id == playerID: return entry.data
            case .broadcast: return entry.data
            case .broadcastExcept(let excluded) where excluded != sessionID: return entry.data
            default: return nil
            }
        }
    }

    func clear() { sent.removeAll() }
}

private struct Fixture {
    let transport = DebugFreezeRecordingTransport()
    let keeper: LandKeeper<DebugFreezeAdapterState>
    let adapter: TransportAdapter<DebugFreezeAdapterState>
    let alice = (session: SessionID("s-alice"), client: ClientID("c-alice"), player: PlayerID("alice"))
    let bob = (session: SessionID("s-bob"), client: ClientID("c-bob"), player: PlayerID("bob"))

    /// `attach: false` builds the adapter for the keeper but never calls `setTransport`.
    init(attach: Bool = true) async throws {
        keeper = LandKeeper<DebugFreezeAdapterState>(
            definition: makeDefinition(),
            initialState: DebugFreezeAdapterState()
        )
        adapter = TransportAdapter<DebugFreezeAdapterState>(
            keeper: keeper,
            transport: transport,
            landID: "debug-freeze-adapter",
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: true,
                syncStrategy: .delta,
                profilingConfig: nil
            )
        )
        await transport.setDelegate(adapter)
        // Tests hold work while frozen: no deadline may fire inside the hold. A test of a
        // deadline sets its own short one (#928).
        await adapter.setDebugFreezeSettleDeadline(freezeWithoutDeadline)
        await adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
        if attach { await keeper.setTransport(adapter) }
        for member in [alice, bob] {
            await adapter.onConnect(sessionID: member.session, clientID: member.client)
            try await simulateRouterJoin(
                adapter: adapter, keeper: keeper,
                sessionID: member.session, clientID: member.client, playerID: member.player
            )
        }
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await transport.clear()
    }

    /// Apply an action for alice; the tickless land applies it before returning.
    func update(headline: String, score: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: DebugFreezeUpdateAction.self),
                payload: AnyCodable(DebugFreezeUpdateAction(headline: headline, score: score))
            ),
            playerID: alice.player, clientID: alice.client, sessionID: alice.session
        )
    }

    func aliceFrames() async -> [Data] {
        await transport.frames(for: alice.session, playerID: alice.player)
    }

    /// Makes the state dirty with no sync after it, so a settle that commits clears the flag
    /// and one that planned nothing leaves it set (the per-player extraction counter can't tell:
    /// with the sync tables on it never moves).
    func makeDirty() async throws {
        try await update(headline: "unsettled", score: 7)
        try #require(await isStillDirty(), "the update left no dirty flag to observe")
    }

    /// Whether `makeDirty`'s change is still dirty: no settle committed it.
    func isStillDirty() async -> Bool {
        await keeper.currentState().getDirtyFields().contains("headline")
    }
}

/// UTF-8 strings appear verbatim in JSON frames.
private func frames(_ frames: [Data], contain marker: String) -> Bool {
    let needle = Data(marker.utf8)
    return frames.contains { $0.range(of: needle) != nil }
}

/// Patches carried by the state updates among `frames` (event frames are skipped).
private func patchCount(_ frames: [Data]) -> Int {
    decodeStateUpdates(frames).reduce(0) { total, update in
        switch update {
        case .noChange: return total
        case .firstSync(let patches), .diff(let patches): return total + patches.count
        }
    }
}

/// Adapter sends may be dispatched in tasks; give them time to land.
private func drainSends() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

/// Wait (bounded) until `condition` holds.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Tests

@Suite("TransportAdapter debug freeze (#79)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct TransportAdapterDebugFreezeTests {

    @Test("Freeze sends a settle cycle with pending changes; projection equals the snapshot of that state")
    func settleAndProjection() async throws {
        let f = try await Fixture()
        try await f.update(headline: "settle-marker-41c2", score: 7)

        let freeze = try await f.adapter.debugFreeze()
        #expect(freeze.freezeCount == 1)
        #expect(freeze.reused == false)
        await drainSends()
        #expect(frames(await f.aliceFrames(), contain: "settle-marker-41c2"), "settle cycle did not send the pending change")

        let state = await f.keeper.currentState()
        let projection = try await f.adapter.debugProjection(playerID: f.alice.player)
        #expect(projection.freezeToken == freeze.freezeToken)
        #expect(projection.playerID == "alice")
        #expect(projection.membershipChanged == false)
        #expect(projection.state == (try SyncEngine(for: type(of: state)).snapshot(for: f.alice.player, from: state, mode: .all)).values)
        #expect(projection.state["headline"] == .string("settle-marker-41c2"))
        #expect(projection.state["scores"] != nil, "per-player field missing from player projection")

        let broadcast = try await f.adapter.debugProjection(playerID: nil)
        #expect(broadcast.playerID == nil)
        #expect(broadcast.state == (try SyncEngine(for: type(of: state)).extractBroadcastSnapshot(from: state, mode: .all)).values)
        #expect(broadcast.state["scores"] == nil, "per-player field in broadcast-only projection")

        // The projection leaves the diff caches alone: after resume nothing is left to send.
        await f.transport.clear()
        let resume = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        #expect(resume == DebugResumeResponse(freezeCount: 0, resumed: true))
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await drainSends()
        #expect(patchCount(await f.aliceFrames()) == 0)
    }

    @Test("Freeze is reference counted; a second freeze reuses the token without a new settle")
    func refCountedFreeze() async throws {
        let f = try await Fixture()
        let first = try await f.adapter.debugFreeze()
        await drainSends()
        await f.transport.clear()

        let second = try await f.adapter.debugFreeze()
        #expect(second.freezeToken == first.freezeToken)
        #expect(second.reused)
        #expect(second.freezeCount == 2)
        await drainSends()
        #expect(await f.aliceFrames().isEmpty, "second freeze sent frames")

        let token = first.freezeToken
        #expect(await f.adapter.debugResume(freezeToken: "unknown") == DebugResumeResponse(freezeCount: 2, resumed: false))
        #expect(await f.adapter.debugResume(freezeToken: token) == DebugResumeResponse(freezeCount: 1, resumed: false))
        #expect(await f.adapter.isDebugFrozen())
        #expect(await f.keeper.isDebugFrozen())
        #expect(await f.adapter.debugResume(freezeToken: token) == DebugResumeResponse(freezeCount: 0, resumed: true))
        #expect(await f.adapter.isDebugFrozen() == false)
        #expect(await f.keeper.isDebugFrozen() == false)
        #expect(await f.adapter.debugResume(freezeToken: token) == DebugResumeResponse(freezeCount: 0, resumed: false))
    }

    @Test("Projection without a freeze throws notFrozen")
    func projectionRequiresFreeze() async throws {
        let f = try await Fixture()
        await #expect(throws: DebugFreezeError.notFrozen) {
            try await f.adapter.debugProjection(playerID: f.alice.player)
        }
    }

    @Test("While frozen, syncNow and a leave's sync send nothing; they run on resume")
    func syncsDeferredWhileFrozen() async throws {
        let f = try await Fixture()
        let token = try await f.adapter.debugFreeze().freezeToken
        await drainSends()
        await f.transport.clear()

        // Bob leaves: OnLeave removes him from a broadcast map and requests a broadcast-only sync.
        await f.adapter.onDisconnect(sessionID: f.bob.session, clientID: f.bob.client)
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await drainSends()
        #expect(patchCount(await f.aliceFrames()) == 0, "a sync ran while frozen")

        let projection = try await f.adapter.debugProjection(playerID: f.alice.player)
        #expect(projection.membershipChanged, "leave during freeze not flagged")

        _ = await f.adapter.debugResume(freezeToken: token)
        await drainSends()
        #expect(patchCount(await f.aliceFrames()) > 0, "deferred sync did not run on resume")
    }

    @Test("A join during freeze sets membershipChanged")
    func joinFlagsMembershipChange() async throws {
        let f = try await Fixture()
        let token = try await f.adapter.debugFreeze().freezeToken
        let carol = (session: SessionID("s-carol"), client: ClientID("c-carol"), player: PlayerID("carol"))
        await f.adapter.onConnect(sessionID: carol.session, clientID: carol.client)
        try await simulateRouterJoin(
            adapter: f.adapter, keeper: f.keeper,
            sessionID: carol.session, clientID: carol.client, playerID: carol.player
        )
        #expect(try await f.adapter.debugProjection(playerID: f.alice.player).membershipChanged)
        _ = await f.adapter.debugResume(freezeToken: token)
    }

    @Test("Auto-resume after the timeout; each freeze call restarts the timer")
    func autoResumeTimeoutResetsOnFreeze() async throws {
        let f = try await Fixture()
        // Each timer fires at once and is held where it fired, so the test decides when each one
        // acts instead of racing its timeout against sleeps (#502).
        await f.adapter.setDebugFreezeAutoResumeTimeout(.zero)
        let first = TestGate(), second = TestGate(), stale = TestGate()
        stale.open()
        let holds = HoldRegistry<TransportAdapterHoldPoint>()
            .on(.debugFreezeAutoResumeFired, arrival: 1) { await first.arrive() }
            .on(.debugFreezeAutoResumeFired, arrival: 2) { await second.arrive() }
            .on(.debugFreezeAutoResumeStale) { await stale.arrive() }
        await f.adapter.installHolds(holds.hook)

        _ = try await f.adapter.debugFreeze()
        #expect(await first.waitForArrivals(1), "the first timer did not fire")
        // The second freeze call restarts the timer: the first one is replaced.
        _ = try await f.adapter.debugFreeze()
        #expect(await second.waitForArrivals(1), "the restarted timer did not fire")

        first.open()
        #expect(await stale.waitForArrivals(1), "the replaced timer did not stand down")
        // Only the restarted timer, still held, could have resumed.
        #expect(await f.adapter.isDebugFrozen())

        // The restarted timer's task, taken before it runs: its resume clears the field.
        let timer = try #require(await f.adapter.debugFreezeState.autoResumeTask)
        second.open()
        await timer.value
        #expect(await f.adapter.isDebugFrozen() == false, "freeze did not auto-resume")
        #expect(await f.keeper.isDebugFrozen() == false)
        #expect(holds.arrivalCount(at: .debugFreezeAutoResumeStale) == 1)
        await f.adapter.installHolds(nil)
    }

    @Test("Auto-resume timeout reads DEBUG_FREEZE_TIMEOUT_SECONDS")
    func autoResumeTimeoutFromEnvironment() {
        #expect(DebugFreezeDefaults.autoResumeTimeout(environment: [:]) == .seconds(30))
        #expect(DebugFreezeDefaults.autoResumeTimeout(environment: [EnvKeys.Debug.freezeTimeoutSeconds: "2.5"]) == .milliseconds(2500))
    }

    @Test("A stale token after auto-resume does not release a newer freeze")
    func staleTokenAfterAutoResume() async throws {
        let f = try await Fixture()
        await f.adapter.setDebugFreezeAutoResumeTimeout(.milliseconds(100))
        let clientA = try await f.adapter.debugFreeze()
        #expect(await eventually { await f.adapter.isDebugFrozen() == false }, "auto-resume did not fire")

        await f.adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
        let clientB = try await f.adapter.debugFreeze()
        #expect(clientB.freezeToken != clientA.freezeToken)
        #expect(clientB.reused == false)

        // Client A's `finally` resume arrives late.
        #expect(await f.adapter.debugResume(freezeToken: clientA.freezeToken) == DebugResumeResponse(freezeCount: 1, resumed: false))
        #expect(await f.adapter.isDebugFrozen(), "a stale token released the newer freeze")
        #expect(await f.keeper.isDebugFrozen())
        _ = try await f.adapter.debugProjection(playerID: f.alice.player)

        #expect(await f.adapter.debugResume(freezeToken: clientB.freezeToken) == DebugResumeResponse(freezeCount: 0, resumed: true))
    }

    @Test("Drain has a deadline: a stuck resolver makes freeze fail and leaves the land running")
    func stuckResolverTimesOut() async throws {
        let f = try await Fixture()
        await f.adapter.setDebugFreezeSettleDeadline(.milliseconds(150))
        let gate = DebugFreezeStuckGate.shared
        let stuck = Task {
            _ = try await f.keeper.handleActionEnvelope(
                ActionEnvelope(
                    typeIdentifier: String(describing: DebugFreezeStuckAction.self),
                    payload: AnyCodable(DebugFreezeStuckAction(headline: "stuck-marker"))
                ),
                playerID: f.alice.player, clientID: f.alice.client, sessionID: f.alice.session
            )
        }
        #expect(await eventually { await gate.waitingCount == 1 })

        let start = ContinuousClock.now
        await #expect(throws: DebugFreezeError.settleTimedOut) {
            try await f.adapter.debugFreeze()
        }
        #expect(ContinuousClock.now - start < .seconds(3), "freeze ignored its deadline")
        #expect(await f.adapter.isDebugFrozen() == false)
        #expect(await f.keeper.isDebugFrozen() == false, "the keeper stayed frozen after the failed freeze")

        // Inputs are not held any more, and the late drain does not re-freeze.
        try await f.update(headline: "after-timeout", score: 1)
        #expect(await f.keeper.currentState().headline == "after-timeout")
        await gate.open()
        _ = try await stuck.value
        #expect(await f.keeper.isDebugFrozen() == false)
    }

    @Test("A freeze released before its settle commits reports released, not a token, and plans nothing")
    func releasedBeforeSettleFinished() async throws {
        let f = try await Fixture()
        // The auto-resume fires at once; the settle is held between its writer wait and its
        // keeper job, so the release lands there (#546 L2b).
        await f.adapter.setDebugFreezeAutoResumeTimeout(.zero)
        let settle = TestGate(), fired = TestGate()
        let holds = HoldRegistry<TransportAdapterHoldPoint>()
            .on(.settleBeforeCommit) { await settle.arrive() }
            .on(.debugFreezeAutoResumeFired) { await fired.arrive() }
        await f.adapter.installHolds(holds.hook)
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        #expect(await settle.waitForArrivals(1), "the settle didn't reach its commit")
        #expect(await fired.waitForArrivals(1), "the auto-resume didn't fire")
        let timer = try #require(await f.adapter.debugFreezeState.autoResumeTask)
        fired.open()
        await timer.value
        #expect(await f.keeper.isDebugFrozen() == false, "the auto-resume released the keeper")
        settle.open()

        await #expect(throws: DebugFreezeError.released) {
            try await freeze.value
        }
        #expect(await f.isStillDirty(), "the job's fence planned nothing")
        #expect(await f.adapter.isDebugFrozen() == false)
        #expect(await f.keeper.isDebugFrozen() == false)
        await f.adapter.installHolds(nil)
    }

    @Test("A keeper-side release before the settle's keeper job is caught by the job's fence")
    func keeperReleaseBeforeSettleCommit() async throws {
        let f = try await Fixture()
        let settle = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        #expect(await settle.waitForArrivals(1), "the settle didn't reach its commit")
        // Only the keeper's freeze ends: the adapter's generation is still current, so only the
        // keeper's own check can refuse.
        await f.keeper.debugResume(generation: await f.adapter.debugFreezeState.generation)
        settle.open()

        await #expect(throws: DebugFreezeError.released) {
            try await freeze.value
        }
        #expect(await f.isStillDirty(), "the job's fence planned nothing")
        await f.adapter.installHolds(nil)
    }

    @Test("A settle whose deadline passed before its keeper job times out and plans nothing")
    func settleDeadlineCheckedInTheJob() async throws {
        let f = try await Fixture()
        // Nothing is in flight and the writer is idle, so the drain and the writer wait pass
        // at once; the job's fence then finds the zero deadline passed (#546 L2b).
        await f.adapter.setDebugFreezeSettleDeadline(.zero)
        try await f.makeDirty()
        await #expect(throws: DebugFreezeError.settleTimedOut) {
            try await f.adapter.debugFreeze()
        }
        #expect(await f.isStillDirty(), "the job's fence planned nothing")
        #expect(await f.adapter.isDebugFrozen() == false)
        #expect(await f.keeper.isDebugFrozen() == false)
    }

    @Test("A land that fails before the settle's keeper turn ends the freeze with that failure and plans nothing")
    func settleOfAFailedLandPlansNothing() async throws {
        let f = try await Fixture()
        let settle = TestGate()
        defer { settle.open() }
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        #expect(await settle.waitForArrivals(1), "the settle didn't reach its commit")
        await f.keeper.submitLandFailure(LandFailure(
            kind: .syncEncode, detail: "test failure", position: LandFailurePosition(stage: .syncPhase)
        ))
        #expect(await f.keeper.waitForFailureForTesting())
        settle.open()

        // The turn's fence names the cause (#546 L2d-1), not `released`.
        await expectLandFailure(.syncEncode) { try await freeze.value }
        #expect(await f.isStillDirty(), "the turn's fence planned nothing")
        await f.adapter.installHolds(nil)
    }

    @Test("A freeze released and frozen again before the first settle's keeper job: the old settle reports released, the new one settles")
    func refreezeBeforeSettleCommit() async throws {
        let f = try await Fixture()
        await f.adapter.setDebugFreezeAutoResumeTimeout(.zero)
        // One gate per settle, so each job's outcome is checked on its own.
        let firstSettle = TestGate(), secondSettle = TestGate(), fired = TestGate()
        await f.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>()
            .on(.settleBeforeCommit, arrival: 1) { await firstSettle.arrive() }
            .on(.settleBeforeCommit, arrival: 2) { await secondSettle.arrive() }
            .on(.debugFreezeAutoResumeFired) { await fired.arrive() }
            .hook)
        try await f.makeDirty()

        let adapter = f.adapter
        let first = Task { try await adapter.debugFreeze() }
        try #require(await firstSettle.waitForArrivals(1), "the first settle didn't reach its commit")
        #expect(await fired.waitForArrivals(1), "the auto-resume didn't fire")
        let timer = try #require(await f.adapter.debugFreezeState.autoResumeTask)
        await f.adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
        fired.open()
        await timer.value
        #expect(await f.keeper.isDebugFrozen() == false, "the auto-resume released the first freeze")

        // The second freeze, a new generation, reaches the same point and waits there.
        let second = Task { try await adapter.debugFreeze() }
        try #require(await secondSettle.waitForArrivals(1), "the second settle didn't reach its commit")

        // The first job alone: its fence refuses the old generation and plans nothing.
        firstSettle.open()
        await #expect(throws: DebugFreezeError.released) {
            try await first.value
        }
        #expect(await f.isStillDirty(), "the first settle planned nothing")

        // Then the second job settles the new freeze.
        secondSettle.open()
        let response = try await second.value
        #expect(response.reused == false)
        #expect(await f.adapter.isDebugFrozen())
        #expect(await f.keeper.isDebugFrozen())
        #expect(await !f.isStillDirty(), "the second settle committed")
        await f.adapter.installHolds(nil)
        _ = await f.adapter.debugResume(freezeToken: response.freezeToken)
    }

    @Test("A land shut down before the settle's keeper turn ends the freeze as closed and plans nothing")
    func settleOfAShutDownLandPlansNothing() async throws {
        let f = try await Fixture()
        let settle = TestGate()
        defer { settle.open() }
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        #expect(await settle.waitForArrivals(1), "the settle didn't reach its commit")
        let keeper = f.keeper
        let shutdown = Task { await keeper.forceShutdown() }
        // The drain flag is set in the shutdown turn, before the drain task is installed.
        try #require(await withinHangBound { await keeper.waitUntilDrainStartedForTesting() }, "the shutdown didn't start draining")
        try #require(f.keeper.isDraining)
        settle.open()

        // A draining land is closed (#546 L2d-1), not released.
        await #expect(throws: LandInputRejection.landClosed) {
            try await freeze.value
        }
        #expect(await f.isStillDirty(), "the job's fence planned nothing")
        await f.adapter.installHolds(nil)
        await shutdown.value
    }

    @Test("A shutdown while the settle's drain waits for in-flight work ends the freeze as closed, not timed out (#730)")
    func shutdownDuringTheDrainAnswersClosed() async throws {
        let f = try await Fixture()
        // The action's turn waits at its record, so its work stays in flight and the drain waits.
        let record = TestGate()
        defer { record.open() }
        await f.keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>.at(.turnRecord) { await record.arrive() })
        let update = Task { try await f.update(headline: "held", score: 1) }
        try #require(await record.waitForArrivals(1), "the action's record wasn't held")

        let adapter = f.adapter
        let ended = EventLog()
        let freeze = Task { defer { ended.append("ended") }; return try await adapter.debugFreeze() }
        try #require(await f.keeper.waitUntilFreezeRegistrationsForTesting(1), "the settle's drain didn't wait")
        // The settle has no deadline here (the fixture's), so a timeout can't be the cause.
        let keeper = f.keeper
        let shutdown = Task { await keeper.forceShutdown() }
        let freezeEnded = await ended.waitFor("ended")
        if !freezeEnded { record.open() }
        try #require(freezeEnded, "the shutdown didn't end the settle's drain")
        await #expect(throws: LandInputRejection.landClosed) { _ = try await freeze.value }

        record.open()
        _ = try? await update.value
        await shutdown.value
        await f.keeper.installHolds(nil)
    }

    @Test("Freezing an empty land keeps its dirty flags for the next real sync")
    func emptyLandKeepsDirtyFlags() async throws {
        let f = try await Fixture()
        for member in [f.alice, f.bob] {
            await f.adapter.onDisconnect(sessionID: member.session, clientID: member.client)
        }
        try await f.update(headline: "dirty-while-empty", score: 4)
        #expect(await f.keeper.currentState().getDirtyFields().contains("headline"))

        let freeze = try await f.adapter.debugFreeze()
        #expect(await f.keeper.currentState().getDirtyFields().contains("headline"), "settle cleared dirty flags without a diff")
        #expect(try await f.adapter.debugProjection(playerID: nil).state["headline"] == .string("dirty-while-empty"))
        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
    }

    // MARK: The settle turn (#546 L2d-1)

    @Test("While a settle is held before its keeper turn, an ordinary sync phase still defers to the resume and plans nothing")
    func ordinaryPhaseKeepsTheFrozenDefer() async throws {
        let f = try await Fixture()
        let settle = TestGate()
        defer { settle.open() }
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()
        await f.transport.clear()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try #require(await settle.waitForArrivals(1), "the settle didn't reach its keeper turn")
        // The settle's context rides only in its own phase call: the ordinary phase keeps the
        // frozen defer, so it skips, leaves its sync to the resume and plans nothing.
        let result = await f.keeper.syncTurnNow(via: f.adapter, reason: .syncNow)
        #expect(result == .skipped)
        #expect(await f.adapter.debugFreezeState.deferredSyncNow, "the skipped phase left its sync to the resume")
        #expect(await f.isStillDirty(), "the ordinary phase planned nothing")
        #expect(patchCount(await f.aliceFrames()) == 0, "nothing was sent while the settle was held")
        settle.open()

        let response = try await freeze.value
        #expect(await !f.isStillDirty(), "the settle committed")
        #expect(patchCount(await f.aliceFrames()) > 0, "the settle sent its frames")
        await f.adapter.installHolds(nil)
        _ = await f.adapter.debugResume(freezeToken: response.freezeToken)
    }

    @Test("A released and refrozen freeze, the old settle held before its keeper turn: it is refused and publishes nothing over the new one's result")
    func oldSettleWritesNothingAfterRefreeze() async throws {
        let f = try await Fixture()
        await f.adapter.setDebugFreezeAutoResumeTimeout(.zero)
        let firstSettle = TestGate(), fired = TestGate()
        defer { firstSettle.open(); fired.open() }
        await f.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>()
            .on(.settleBeforeCommit, arrival: 1) { await firstSettle.arrive() }
            .on(.debugFreezeAutoResumeFired) { await fired.arrive() }
            .hook)
        try await f.makeDirty()

        let adapter = f.adapter
        let first = Task { try await adapter.debugFreeze() }
        try #require(await firstSettle.waitForArrivals(1), "the first settle didn't reach its keeper turn")
        #expect(await fired.waitForArrivals(1), "the auto-resume didn't fire")
        let timer = try #require(await f.adapter.debugFreezeState.autoResumeTask)
        await f.adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
        fired.open()
        await timer.value

        // The second freeze settles while the first is still held.
        try await f.update(headline: "second-freeze", score: 9)
        let second = try await f.adapter.debugFreeze()
        let published = try #require(await f.adapter.debugFreezeState.settled)
        #expect(published.state.headline == "second-freeze")

        firstSettle.open()
        await #expect(throws: DebugFreezeError.released) {
            try await first.value
        }
        let after = try #require(await f.adapter.debugFreezeState.settled, "the old settle cleared the new result")
        #expect(after.state.headline == "second-freeze", "the old settle wrote over the new result")
        #expect(try await f.adapter.debugProjection(playerID: nil).state["headline"] == .string("second-freeze"))
        await f.adapter.installHolds(nil)
        _ = await f.adapter.debugResume(freezeToken: second.freezeToken)
    }

    @Test("A released and refrozen freeze, the old settle held before its publish: it committed, and its publish ticket keeps it off the new one's result")
    func oldSettleHeldAtPublishWritesNothingAfterRefreeze() async throws {
        let f = try await Fixture()
        await f.adapter.setDebugFreezeAutoResumeTimeout(.zero)
        let firstPublish = TestGate(), fired = TestGate()
        defer { firstPublish.open(); fired.open() }
        // The auto-resume is held where it fired, so the release lands only after the first
        // settle's keeper turn committed and the settle waits at its publish.
        await f.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>()
            .on(.settleBeforePublish, arrival: 1) { await firstPublish.arrive() }
            .on(.debugFreezeAutoResumeFired) { await fired.arrive() }
            .hook)
        try await f.makeDirty()

        let adapter = f.adapter
        let first = Task { try await adapter.debugFreeze() }
        try #require(await firstPublish.waitForArrivals(1), "the first settle didn't reach its publish")
        #expect(await !f.isStillDirty(), "the first settle's keeper turn committed")
        #expect(await fired.waitForArrivals(1), "the auto-resume didn't fire")
        let timer = try #require(await f.adapter.debugFreezeState.autoResumeTask)
        await f.adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
        fired.open()
        await timer.value
        #expect(await f.adapter.isDebugFrozen() == false, "the auto-resume released the first freeze")

        // The second freeze settles while the first waits at its publish.
        try await f.update(headline: "second-freeze", score: 9)
        let second = try await f.adapter.debugFreeze()
        let published = try #require(await f.adapter.debugFreezeState.settled)
        #expect(published.state.headline == "second-freeze")

        // Only the publish's ticket check keeps the first settle's copy out.
        firstPublish.open()
        await #expect(throws: DebugFreezeError.released) {
            try await first.value
        }
        let after = try #require(await f.adapter.debugFreezeState.settled, "the old settle cleared the new result")
        #expect(after.state.headline == "second-freeze", "the old settle wrote over the new result")
        #expect(try await f.adapter.debugProjection(playerID: nil).state["headline"] == .string("second-freeze"))
        await f.adapter.installHolds(nil)
        _ = await f.adapter.debugResume(freezeToken: second.freezeToken)
    }

    @Test("A settle whose transport output closed before its keeper turn throws the closing failure and plans nothing")
    func closedOutputSurfacesItsCause() async throws {
        let f = try await Fixture()
        let settle = TestGate()
        defer { settle.open() }
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try #require(await settle.waitForArrivals(1), "the settle didn't reach its keeper turn")
        // Only the adapter's gate closes (as a standalone firstSync's failure does before the
        // keeper applies it): the keeper hasn't failed, so only the settle phase can refuse.
        f.adapter.outputGate.close(LandFailure(
            kind: .syncEncode, detail: "closed by the test", position: LandFailurePosition(stage: .syncPhase)
        ))
        settle.open()

        await expectLandFailure(.syncEncode) { try await freeze.value }
        #expect(await f.isStillDirty(), "the refused settle planned nothing")
        await f.adapter.installHolds(nil)
    }

    @Test("A settle through a transport the keeper no longer has attached is refused as released and plans nothing")
    func detachedTransportIsRefused() async throws {
        let f = try await Fixture()
        let settle = TestGate()
        defer { settle.open() }
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try #require(await settle.waitForArrivals(1), "the settle didn't reach its keeper turn")
        await f.keeper.setTransport(nil)
        settle.open()

        await #expect(throws: DebugFreezeError.released) {
            try await freeze.value
        }
        #expect(await f.isStillDirty(), "the refused settle planned nothing")
        await f.adapter.installHolds(nil)
    }

    /// A keeper never attached syncs through the first adapter that asks (`bindSyncRequester`;
    /// here the fixture's `syncNow()` bound it); its settle takes the same rule as the requested
    /// turns, so it settles instead of being refused for having no attached transport (#546 L2d).
    /// The settle's own binding, and that a refused settle binds nothing: SettleFenceBindingTests.
    @Test("A keeper never attached settles through the adapter it syncs with")
    func neverAttachedKeeperSettles() async throws {
        let f = try await Fixture(attach: false)
        #expect(await f.keeper.transportForTesting == nil, "the fixture never attached")
        try await f.makeDirty()

        let freeze = try await f.adapter.debugFreeze()
        #expect(await !f.isStillDirty(), "the settle committed")
        #expect(try #require(await f.adapter.debugFreezeState.settled).state.headline == "unsettled")
        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
    }

    @Test("The fence checks a failed land before the freeze generation: a failed and released land names its failure")
    func fenceChecksClosedBeforeReleased() async throws {
        let f = try await Fixture()
        let settle = TestGate()
        defer { settle.open() }
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try #require(await settle.waitForArrivals(1), "the settle didn't reach its keeper turn")
        await f.keeper.debugResume(generation: await f.adapter.debugFreezeState.generation)
        await f.keeper.submitLandFailure(LandFailure(
            kind: .syncEncode, detail: "test failure", position: LandFailurePosition(stage: .syncPhase)
        ))
        #expect(await f.keeper.waitForFailureForTesting())
        settle.open()

        await expectLandFailure(.syncEncode) { try await freeze.value }
        #expect(await f.isStillDirty(), "the turn's fence planned nothing")
        await f.adapter.installHolds(nil)
    }

    @Test("The fence checks the deadline before the freeze generation: an expired and released settle times out")
    func fenceChecksDeadlineBeforeReleased() async throws {
        let f = try await Fixture()
        // Nothing is in flight and the writer is idle, so the drain and the writer wait pass at
        // once; the turn's fence then finds the zero deadline passed.
        await f.adapter.setDebugFreezeSettleDeadline(.zero)
        let settle = TestGate()
        defer { settle.open() }
        await f.adapter.installHolds(HoldRegistry.at(.settleBeforeCommit) { await settle.arrive() })
        try await f.makeDirty()

        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try #require(await settle.waitForArrivals(1), "the settle didn't reach its keeper turn")
        await f.keeper.debugResume(generation: await f.adapter.debugFreezeState.generation)
        settle.open()

        await #expect(throws: DebugFreezeError.settleTimedOut) {
            try await freeze.value
        }
        #expect(await f.isStillDirty(), "the turn's fence planned nothing")
        await f.adapter.installHolds(nil)
    }
}

/// Expects `body` to throw a `LandFailure` of `kind`.
private func expectLandFailure(
    _ kind: LandFailure.Kind,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> some Any
) async {
    do {
        _ = try await body()
        Issue.record("expected a land failure of kind \(kind)", sourceLocation: sourceLocation)
    } catch let failure as LandFailure {
        #expect(failure.kind == kind, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected a land failure of kind \(kind), got \(error)", sourceLocation: sourceLocation)
    }
}
