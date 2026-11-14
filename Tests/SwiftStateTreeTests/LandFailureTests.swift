// Tests for #535 part A: a sync failure ends the land, keeper side.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct LandFailureTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    /// What ran, in order: "join", "leave", "action", "finalize".
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@Payload
struct LandFailureAddAction: ActionPayload {
    typealias Response = LandFailureAck
    let amount: Int
}

@Payload
struct LandFailureAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct LandFailureResolvedAction: ActionPayload {
    typealias Response = LandFailureAck
    let amount: Int
}

struct LandFailureResolverOutput: ResolverOutput {
    let value: Int
}

/// A resolver that returns at once: the action is a tickless action job (#535: its own turn's
/// failure must not cancel it).
struct LandFailureResolver: ContextResolver {
    typealias Output = LandFailureResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> LandFailureResolverOutput {
        LandFailureResolverOutput(value: (ctx.actionPayload as? LandFailureResolvedAction)?.amount ?? 0)
    }
}

/// The cause each destroy handler saw, in order.
private final class SeenCauses: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ entry: String) { lock.lock(); list.append(entry); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

private func makeFailureDefinition(_ finalized: SeenCauses) -> LandDefinition<LandFailureTestState> {
    Land("land-failure-test", using: LandFailureTestState.self) {
        Rules {
            OnJoin { (state: inout LandFailureTestState, _: LandContext) in
                state.log.append("join")
            }
            OnLeave { (state: inout LandFailureTestState, _: LandContext) in
                state.log.append("leave")
            }
            HandleAction(LandFailureAddAction.self) {
                (state: inout LandFailureTestState, action: LandFailureAddAction, ctx: LandContext) in
                state.total += action.amount
                state.log.append("action")
                ctx.requestSyncNow()
                return LandFailureAck(ok: true)
            }
            HandleAction(LandFailureResolvedAction.self, resolvers: LandFailureResolver.self) {
                (state: inout LandFailureTestState, action: LandFailureResolvedAction, ctx: LandContext) in
                state.total += action.amount
                state.log.append("resolved")
                ctx.requestSyncNow()
                return LandFailureAck(ok: true)
            }
        }
        Lifetime {
            OnFinalize { (state: inout LandFailureTestState, _: LandContext) in
                finalized.append("finalize:\(state.log.joined(separator: ","))")
            }
        }
    }
}

/// A custom in-turn transport that keeps the protocol's default `landDidFail`; its sync phase
/// reports `.landFailed` once `failing` is set.
private final class FailingInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var failingStorage = false
    private var destroyedStorage = 0

    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failingStorage }
        set { lock.lock(); failingStorage = newValue; lock.unlock() }
    }

    var destroyed: Int { lock.lock(); defer { lock.unlock() }; return destroyedStorage }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async { lock.withLock { destroyedStorage += 1 } }
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(syncPhaseResult(state: state, events: events, includeSync: includeSync))
    }

    private func syncPhaseResult<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        guard includeSync else { return .notRequested }
        guard failing else { return .committed(clearDirtyFlags: true) }
        return .landFailed(LandFailure(kind: .syncPlan, detail: "test plan threw", position: LandFailurePosition(stage: .syncPhase)))
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")

private func addAction(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: LandFailureAddAction.self),
                   payload: AnyCodable(LandFailureAddAction(amount: amount)))
}

@Suite("A sync failure ends the land: keeper (#535)", .timeLimit(.minutes(1)))
struct LandFailureKeeperTests {
    private func make() async -> (LandKeeper<LandFailureTestState>, FailingInTurnTransport, SeenCauses) {
        let transport = FailingInTurnTransport()
        let finalized = SeenCauses()
        let keeper = LandKeeper<LandFailureTestState>(
            definition: makeFailureDefinition(finalized),
            initialState: LandFailureTestState(),
            autoStartLoops: false,
            transport: transport
        )
        return (keeper, transport, finalized)
    }

    @Test("a custom transport with the default landDidFail: the land ends with .failed while players are in it, without OnLeave")
    func customTransportWithDefaultHookTearsDown() async throws {
        let (keeper, transport, finalized) = await make()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        transport.failing = true
        _ = try await keeper.handleActionEnvelope(addAction(1), playerID: p1, clientID: c1, sessionID: s1)

        // The failing turn set the cause and stored the failure before it returned.
        #expect(keeper.destructionCause == .failed)
        #expect(keeper.failure?.kind == .syncPlan)
        #expect(keeper.failure?.position.stage == .syncPhase)
        await keeper.waitUntilDrained()
        #expect(transport.destroyed == 1)
        // The destroy ran with both players' joins and the action, and no OnLeave.
        #expect(finalized.all == ["finalize:join,join,action"])
    }

    @Test("after the failure, actions and joins are refused with landClosed")
    func intakeIsClosed() async throws {
        let (keeper, transport, _) = await make()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        transport.failing = true
        _ = try await keeper.handleActionEnvelope(addAction(1), playerID: p1, clientID: c1, sessionID: s1)
        try #require(keeper.isDraining, "the action's sync phase failed the land")
        await #expect(throws: (any Error).self) {
            _ = try await keeper.handleActionEnvelope(addAction(2), playerID: p1, clientID: c1, sessionID: s1)
        }
        await #expect(throws: (any Error).self) {
            try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        }
        await keeper.waitUntilDrained()
    }

    @Test("the teardown's synchronous part ran in the failing turn: at the teardown task's hold, the players are gone and a forceShutdown joins it")
    func teardownStartsInTheFailingTurn() async throws {
        let (keeper, transport, finalized) = await make()
        let gate = TestHoldGate()
        await keeper.installHolds(HoldRegistry.at(.landFailedTeardown) { await gate.arrive() })
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        transport.failing = true
        _ = try await keeper.handleActionEnvelope(addAction(1), playerID: p1, clientID: c1, sessionID: s1)
        // Without a failure the teardown never reaches the hold: stop here rather than wait.
        try #require(keeper.failure != nil, "the action's sync phase failed the land")
        try #require(await gate.waitUntilArrived(), "the teardown reached its hold")
        #expect(await keeper.playerCount() == 0, "players cleared in the failing segment")
        let shutdown = Task { await keeper.forceShutdown() }
        #expect(finalized.all.isEmpty, "no destroy while the teardown is held")
        gate.open()
        await shutdown.value
        #expect(finalized.all.count == 1, "one destroy: \(finalized.all)")
        #expect(keeper.destructionCause == .failed, "the first cause stays")
    }

    @Test("an action job whose own turn fails the land gets its handler's response, not landClosed")
    func actionJobInTheFailingTurnKeepsItsOutcome() async throws {
        let (keeper, transport, finalized) = await make()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        transport.failing = true
        let envelope = ActionEnvelope(typeIdentifier: String(describing: LandFailureResolvedAction.self),
                                      payload: AnyCodable(LandFailureResolvedAction(amount: 3)))
        let response = try await keeper.handleActionEnvelope(envelope, playerID: p1, clientID: c1, sessionID: s1)
        #expect((response.base as? LandFailureAck)?.ok == true, "the consumed input keeps its outcome")
        #expect(keeper.failure?.kind == .syncPlan)
        await keeper.waitUntilDrained()
        #expect(finalized.all == ["finalize:join,resolved"])
    }

    @Test("a second failure keeps the first: the stored failure, one teardown, one destroy")
    func firstFailureWins() async throws {
        let (keeper, transport, finalized) = await make()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        transport.failing = true
        _ = try await keeper.handleActionEnvelope(addAction(1), playerID: p1, clientID: c1, sessionID: s1)
        let first = try #require(keeper.failure)
        let second = LandFailure(kind: .eventEncode, detail: "second", position: LandFailurePosition(stage: .eventFlush))
        await keeper.failLandForTesting(second)
        #expect(keeper.failure == first)
        await keeper.waitUntilDrained()
        #expect(keeper.failure == first)
        #expect(keeper.destructionCause == .failed)
        #expect(transport.destroyed == 1)
        #expect(finalized.all.count == 1)
    }

    @Test("a failure after a shutdown began doesn't replace its cause")
    func failureAfterAShutdownKeepsTheShutdown() async throws {
        let (keeper, transport, finalized) = await make()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.forceShutdown()
        await keeper.failLandForTesting(
            LandFailure(kind: .syncPlan, detail: "late", position: LandFailurePosition(stage: .syncPhase)))
        #expect(keeper.destructionCause == .forceShutdown)
        #expect(keeper.failure == nil)
        #expect(transport.destroyed == 1)
        #expect(finalized.all.count == 1)
    }
}

/// A one-shot hold: `arrive` waits until `open`; `waitUntilArrived` until someone arrived.
private final class TestHoldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var arrived = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var nextWaiterID = 0

    func arrive() async {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            arrived = true
            let w = Array(arrivalWaiters.values)
            arrivalWaiters.removeAll()
            return w
        }
        waiters.forEach { $0.resume(returning: true) }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if opened { return true }
                openWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Resumed by the arrival, not by polling. `false` after a 60 s hang guard: a suite's time
    /// limit cancels the test's task, but a continuation that is never resumed ignores the
    /// cancellation, so without this bound a missing arrival hangs the whole test process.
    func waitUntilArrived() async -> Bool {
        let id = lock.withLock { () -> Int in
            defer { nextWaiterID += 1 }
            return nextWaiterID
        }
        let hangGuard = Task { [weak self] in
            try? await safeTaskSleep(for: .seconds(60))
            self?.expire(id)
        }
        defer { hangGuard.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumeNow: Bool = lock.withLock {
                if arrived { return true }
                arrivalWaiters[id] = continuation
                return false
            }
            if resumeNow { continuation.resume(returning: true) }
        }
    }

    private func expire(_ id: Int) {
        let waiter = lock.withLock { arrivalWaiters.removeValue(forKey: id) }
        waiter?.resume(returning: false)
    }

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let w = openWaiters
            openWaiters.removeAll()
            return w
        }
        waiters.forEach { $0.resume() }
    }
}
