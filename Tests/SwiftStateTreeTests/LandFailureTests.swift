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
                (state: inout LandFailureTestState, action: LandFailureAddAction, _: LandContext) in
                state.total += action.amount
                state.log.append("action")
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
        #expect(keeper.isDraining)
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
        await gate.waitUntilArrived()
        #expect(await keeper.playerCount() == 0, "players cleared in the failing segment")
        let shutdown = Task { await keeper.forceShutdown() }
        #expect(finalized.all.isEmpty, "no destroy while the teardown is held")
        gate.open()
        await shutdown.value
        #expect(finalized.all.count == 1, "one destroy: \(finalized.all)")
        #expect(keeper.destructionCause == .failed, "the first cause stays")
    }

    @Test("a further failure after the first keeps the first")
    func firstFailureWins() async throws {
        let (keeper, transport, _) = await make()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        transport.failing = true
        _ = try await keeper.handleActionEnvelope(addAction(1), playerID: p1, clientID: c1, sessionID: s1)
        let first = keeper.failure
        await keeper.waitUntilDrained()
        #expect(keeper.failure == first)
    }
}

/// A one-shot hold: `arrive` waits until `open`; `waitUntilArrived` until someone arrived.
private final class TestHoldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var arrived = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            arrived = true
            let w = arrivalWaiters
            arrivalWaiters.removeAll()
            return w
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if opened { return true }
                openWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilArrived() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if arrived { return true }
                arrivalWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
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
