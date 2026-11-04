// Tests/SwiftStateTreeTransportTests/TransportAdapterDebugFreezeTests.swift
//
// TransportAdapter.debugFreeze(): settle cycle, projection from the settle copy, reference
// counting, auto-resume, and syncs deferred while frozen (#79).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

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

struct DebugFreezeStuckResolver: ContextResolver {
    typealias Output = DebugFreezeStuckOutput

    static func resolve(ctx: ResolverContext) async throws -> DebugFreezeStuckOutput {
        await DebugFreezeStuckGate.shared.pass()
        return DebugFreezeStuckOutput(ok: true)
    }
}

struct DebugFreezeStuckOutput: ResolverOutput {
    let ok: Bool
}

/// Tickless land; leaving removes the player from a broadcast map, which requests a
/// broadcast-only sync.
private func makeDefinition() -> LandDefinition<DebugFreezeAdapterState> {
    Land("debug-freeze-adapter", using: DebugFreezeAdapterState.self) {
        Rules {
            OnJoin { (state: inout DebugFreezeAdapterState, ctx: LandContext) in
                state.members[ctx.playerID] = true
            }
            OnLeave { (state: inout DebugFreezeAdapterState, ctx: LandContext) in
                state.members.removeValue(forKey: ctx.playerID)
            }
            HandleAction(DebugFreezeStuckAction.self, resolvers: DebugFreezeStuckResolver.self) {
                (state: inout DebugFreezeAdapterState, action: DebugFreezeStuckAction, _: LandContext) in
                state.headline = action.headline
                return DebugFreezeUpdateAck(ok: true)
            }
            HandleAction(DebugFreezeUpdateAction.self) {
                (state: inout DebugFreezeAdapterState, action: DebugFreezeUpdateAction, ctx: LandContext) in
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

    init() async throws {
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
                enableChangeObjectMetrics: false,
                changeObjectMetricsLogEvery: 10,
                changeObjectMetricsEmaAlpha: 0.2,
                enableAutoDirtyTracking: false,
                autoDirtyOffThreshold: 0.55,
                autoDirtyOnThreshold: 0.30,
                autoDirtyRequiredConsecutiveSamples: 30,
                profilingConfig: nil
            )
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        for member in [alice, bob] {
            await adapter.onConnect(sessionID: member.session, clientID: member.client)
            try await simulateRouterJoin(
                adapter: adapter, keeper: keeper,
                sessionID: member.session, clientID: member.client, playerID: member.player
            )
        }
        await adapter.syncNow()
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

private actor DoneFlag {
    private(set) var isDone = false
    func set() { isDone = true }
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

@Suite("TransportAdapter debug freeze (#79)", .timeLimit(.minutes(1)))
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
        #expect(projection.state == (try SyncEngine().snapshot(for: f.alice.player, from: state, mode: .all)).values)
        #expect(projection.state["headline"] == .string("settle-marker-41c2"))
        #expect(projection.state["scores"] != nil, "per-player field missing from player projection")

        let broadcast = try await f.adapter.debugProjection(playerID: nil)
        #expect(broadcast.playerID == nil)
        #expect(broadcast.state == (try SyncEngine().extractBroadcastSnapshot(from: state, mode: .all)).values)
        #expect(broadcast.state["scores"] == nil, "per-player field in broadcast-only projection")

        // The projection leaves the diff caches alone: after resume nothing is left to send.
        await f.transport.clear()
        let resume = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        #expect(resume == DebugResumeResponse(freezeCount: 0, resumed: true))
        await f.adapter.syncNow()
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

    @Test("Settle waits for a sync cycle already in flight, then runs its own")
    func settleRetriesUntilBeginSyncAccepts() async throws {
        let f = try await Fixture()
        try await f.update(headline: "retry-marker-7d0e", score: 1)

        // Hold the keeper's sync flag, as a running cycle would.
        let held = await f.keeper.beginSync(clearDirtyFlags: false)
        #expect(held != nil)

        let done = DoneFlag()
        let freeze = Task {
            let response = try await f.adapter.debugFreeze()
            await done.set()
            return response
        }
        await drainSends()
        #expect(await done.isDone == false, "freeze returned while beginSync was rejecting")

        await f.keeper.endSync()
        let token = try await freeze.value.freezeToken
        await drainSends()
        #expect(frames(await f.aliceFrames(), contain: "retry-marker-7d0e"))
        _ = await f.adapter.debugResume(freezeToken: token)
    }

    @Test("While frozen, syncNow, syncBroadcastOnly and a leave's sync send nothing; they run on resume")
    func syncsDeferredWhileFrozen() async throws {
        let f = try await Fixture()
        let token = try await f.adapter.debugFreeze().freezeToken
        await drainSends()
        await f.transport.clear()

        // Bob leaves: OnLeave removes him from a broadcast map and requests a broadcast-only sync.
        await f.adapter.onDisconnect(sessionID: f.bob.session, clientID: f.bob.client)
        await f.adapter.syncNow()
        await f.adapter.syncBroadcastOnly()
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
        await f.adapter.setDebugFreezeAutoResumeTimeout(.milliseconds(400))

        _ = try await f.adapter.debugFreeze()
        try await Task.sleep(for: .milliseconds(250))
        _ = try await f.adapter.debugFreeze()
        try await Task.sleep(for: .milliseconds(250))
        // 500 ms after the first call, 250 ms after the second: the restarted timer has not fired.
        #expect(await f.adapter.isDebugFrozen())

        var resumed = false
        for _ in 0..<200 {
            if await f.adapter.isDebugFrozen() == false {
                resumed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resumed, "freeze did not auto-resume")
        #expect(await f.keeper.isDebugFrozen() == false)
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

        await f.adapter.setDebugFreezeAutoResumeTimeout(.seconds(30))
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

    @Test("A freeze released before its settle finished reports released, not a token")
    func releasedBeforeSettleFinished() async throws {
        let f = try await Fixture()
        await f.adapter.setDebugFreezeAutoResumeTimeout(.milliseconds(100))
        // Hold the sync flag so the settle keeps retrying past the auto-resume.
        _ = await f.keeper.beginSync(clearDirtyFlags: false)

        await #expect(throws: DebugFreezeError.released) {
            try await f.adapter.debugFreeze()
        }
        #expect(await f.adapter.isDebugFrozen() == false)
        #expect(await f.keeper.isDebugFrozen() == false)
        await f.keeper.endSync()
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
}
