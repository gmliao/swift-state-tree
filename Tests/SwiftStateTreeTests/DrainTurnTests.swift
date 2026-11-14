// Tests/SwiftStateTreeTests/DrainTurnTests.swift
//
// The drain (land destruction) closes intake when it starts, waits for a tick in flight, drops
// the pending inputs, and runs each destroy handler as "resolvers, then one synchronous
// segment". No input is applied during or after the destroy handlers.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct DrainTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    /// What ran, in order: "join", "leave", "tick", "action", "finalize".
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@Payload
struct DrainPlainAction: ActionPayload {
    typealias Response = DrainAck
    let amount: Int
}

@Payload
struct DrainGatedAction: ActionPayload {
    typealias Response = DrainAck
    /// Also the key of the resolver's gate (`DeliveryGates`).
    let amount: Int
}

@Payload
struct DrainAck: ResponsePayload {
    let ok: Bool
}

struct DrainResolverOutput: ResolverOutput {
    let value: Int
}

/// Gate key of a held OnFinalize or lifecycle resolver: the land ID's numeric suffix
/// ("drain-finalize:<n>", "drain-lifecycle:<n>"), a key from `DeliveryGates.freshKey()`, so each
/// test (and each case of a parameterized one) has its own gate.
private func landGateKey(landID: String) -> Int {
    Int(landID.split(separator: ":").last ?? "") ?? 0
}

struct DrainActionResolver: ContextResolver {
    typealias Output = DrainResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> DrainResolverOutput {
        let amount = (ctx.actionPayload as? DrainGatedAction)?.amount ?? -1
        await DeliveryGates.gate(amount).enterAndWait()
        return DrainResolverOutput(value: amount)
    }
}

struct DrainFinalizeResolver: ContextResolver {
    typealias Output = DrainResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> DrainResolverOutput {
        await DeliveryGates.gate(landGateKey(landID: ctx.landID)).enterAndWait()
        return DrainResolverOutput(value: 0)
    }
}

private func makeDrainDefinition(tick: Bool, finalizeResolver: Bool = false) -> LandDefinition<DrainTestState> {
    if tick {
        return Land("drain-test", using: DrainTestState.self) {
            Rules {
                OnJoin { (state: inout DrainTestState, _: LandContext) in
                    state.log.append("join")
                }
                // On the legacy tick path an applied OnLeave awaits the broadcast sync before
                // the tick handler; one test holds the tick there.
                OnLeave { (state: inout DrainTestState, _: LandContext) in
                    state.log.append("leave")
                }
                HandleAction(DrainPlainAction.self) {
                    (state: inout DrainTestState, action: DrainPlainAction, _: LandContext) in
                    state.total += action.amount
                    state.log.append("action")
                    return DrainAck(ok: true)
                }
                HandleAction(DrainGatedAction.self, resolvers: DrainActionResolver.self) {
                    (state: inout DrainTestState, action: DrainGatedAction, _: LandContext) in
                    state.total += action.amount
                    state.log.append("action")
                    return DrainAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout DrainTestState, _: LandContext) in
                    state.log.append("tick")
                }
                OnFinalize { (state: inout DrainTestState, _: LandContext) in
                    state.log.append("finalize")
                }
            }
        }
    }
    if finalizeResolver {
        return Land("drain-test", using: DrainTestState.self) {
            Rules {
                OnJoin { (state: inout DrainTestState, _: LandContext) in
                    state.log.append("join")
                }
                HandleAction(DrainPlainAction.self) {
                    (state: inout DrainTestState, action: DrainPlainAction, _: LandContext) in
                    state.total += action.amount
                    state.log.append("action")
                    return DrainAck(ok: true)
                }
                HandleAction(DrainGatedAction.self, resolvers: DrainActionResolver.self) {
                    (state: inout DrainTestState, action: DrainGatedAction, _: LandContext) in
                    state.total += action.amount
                    state.log.append("action")
                    return DrainAck(ok: true)
                }
            }
            Lifetime {
                OnFinalize(resolvers: DrainFinalizeResolver.self) { (state: inout DrainTestState, _: LandContext) in
                    state.log.append("finalize")
                }
            }
        }
    }
    return Land("drain-test", using: DrainTestState.self) {
        Rules {
            OnJoin { (state: inout DrainTestState, _: LandContext) in
                state.log.append("join")
            }
            HandleAction(DrainPlainAction.self) {
                (state: inout DrainTestState, action: DrainPlainAction, _: LandContext) in
                state.total += action.amount
                state.log.append("action")
                return DrainAck(ok: true)
            }
            HandleAction(DrainGatedAction.self, resolvers: DrainActionResolver.self) {
                (state: inout DrainTestState, action: DrainGatedAction, _: LandContext) in
                state.total += action.amount
                state.log.append("action")
                return DrainAck(ok: true)
            }
        }
        Lifetime {
            OnFinalize { (state: inout DrainTestState, _: LandContext) in
                state.log.append("finalize")
            }
        }
    }
}

/// Holds the next `syncBroadcastOnlyFromTransport` after `arm()`: on the legacy tick path an
/// applied OnLeave awaits it inside `processPendingActions`, before the tick handler.
private actor BroadcastHoldTransport: LandKeeperTransport {
    let gate = WatermarkGate()
    private var armed = false

    func arm() { armed = true }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {
        if armed {
            armed = false
            await gate.enterAndWait()
        }
    }
    func onLandDestroyed() async {}
}

/// Reports in-turn sync for every keeper and commits each requested sync phase, so a keeper
/// attached to it takes the in-turn path whatever `IN_TURN_SYNC` says. Not an actor: its
/// synchronous calls need no isolation.
private final class DrainInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
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
        includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// Awaits `task` within the deadline and expects `.landClosed`; a hang fails as `step`.
private func expectLandClosed(
    _ step: String,
    _ task: Task<AnyCodable, Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    guard let result = try await withinDeadline(step, sourceLocation: sourceLocation, { await task.result }) else {
        return
    }
    switch result {
    case .success:
        Issue.record("Expected landClosed", sourceLocation: sourceLocation)
    case .failure(let error):
        #expect(error as? LandInputRejection == .landClosed, sourceLocation: sourceLocation)
    }
}

private func expectLandClosed(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected landClosed")
    } catch let rejection as LandInputRejection {
        #expect(rejection == .landClosed)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

/// The player whose lifecycle resolvers hold on a gate; every other player's pass.
private let heldLeaver = PlayerID("held-leaver")
private let heldJoiner = PlayerID("held-joiner")

struct DrainLeaveResolver: ContextResolver {
    typealias Output = DrainResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> DrainResolverOutput {
        if ctx.playerID == heldLeaver {
            await DeliveryGates.gate(landGateKey(landID: ctx.landID)).enterAndWait()
        }
        return DrainResolverOutput(value: 0)
    }
}

struct DrainJoinResolver: ContextResolver {
    typealias Output = DrainResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> DrainResolverOutput {
        if ctx.playerID == heldJoiner {
            await DeliveryGates.gate(landGateKey(landID: ctx.landID)).enterAndWait()
        }
        return DrainResolverOutput(value: 0)
    }
}

/// Tickless, with lifecycle resolvers and destroy-when-empty after 1 ms.
private func makeLifecycleDrainDefinition() -> LandDefinition<DrainTestState> {
    Land("drain-test", using: DrainTestState.self) {
        Rules {
            OnJoin(resolvers: DrainJoinResolver.self) { (state: inout DrainTestState, ctx: LandContext) in
                state.log.append("join:\(ctx.playerID.rawValue)")
            }
            OnLeave(resolvers: DrainLeaveResolver.self) { (state: inout DrainTestState, ctx: LandContext) in
                state.log.append("leave:\(ctx.playerID.rawValue)")
            }
        }
        Lifetime {
            DestroyWhenEmpty(after: .milliseconds(1)) { (_: inout DrainTestState, _: LandContext) in }
            OnFinalize { (state: inout DrainTestState, _: LandContext) in
                state.log.append("finalize")
            }
        }
    }
}

/// Holds the end of the drain (`onLandDestroyed`, after the destroy handlers) on `gate`.
private actor DestroyHoldTransport: LandKeeperTransport {
    let gate = WatermarkGate()

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async { await gate.enterAndWait() }
}

private func makeLifecycleKeeper(
    gateKey: Int,
    transport: (any LandKeeperTransport)? = nil
) async -> LandKeeper<DrainTestState> {
    let keeper = LandKeeper<DrainTestState>(
        definition: makeLifecycleDrainDefinition(),
        initialState: DrainTestState(),
        autoStartLoops: false,
        transport: transport
    )
    await keeper.setLandID("drain-lifecycle:\(gateKey)")
    return keeper
}

private func plainAction(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: DrainPlainAction.self),
                   payload: AnyCodable(DrainPlainAction(amount: amount)))
}

@Suite("Drain as turns", .timeLimit(.minutes(1)))
struct DrainTurnTests {
    @Test("A destroyed keeper drops its transport only after the transport's last call, onLandDestroyed (#346)")
    func transportReleasedAfterLandDestroyed() async throws {
        let transport = DestroyHoldTransport()
        weak var weakTransport: DestroyHoldTransport? = transport
        let keeper = await makeLifecycleKeeper(gateKey: DeliveryGates.freshKey(), transport: transport)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let drain = Task { await keeper.forceShutdown() }
        // Held inside onLandDestroyed: the transport is still attached during its last call.
        await transport.gate.waitUntilEntered()
        #expect(await keeper.transportForTesting is DestroyHoldTransport, "attached while onLandDestroyed runs")
        transport.gate.release()
        await drain.value
        #expect(await keeper.transportForTesting is ReleasedLandTransport, "dropped for the placeholder once onLandDestroyed returned")
        // Late keeper work still reaches a transport, the released placeholder, which counts it.
        #expect(await keeper.transportCallsAfterDestruction == 0)
        await keeper.transportForTesting?.syncNowFromTransport()
        await keeper.transportForTesting?.sendEventToTransport(AnyServerEvent(type: "late", payload: AnyCodable([String: Int]())), to: .all)
        #expect(await keeper.transportCallsAfterDestruction == 2, "late calls are counted, not dropped silently")
        _ = consume transport
        #expect(weakTransport == nil, "the keeper no longer keeps its transport alive")
    }

    @Test("Legacy tick: a drain while a tick is suspended before its handler waits for the whole tick")
    func drainWaitsForTickInFlight() async throws {
        let transport = BroadcastHoldTransport()
        let keeper = LandKeeper<DrainTestState>(
            definition: makeDrainDefinition(tick: true),
            initialState: DrainTestState(),
            autoStartLoops: false,
            transport: transport
        )
        let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()

        // The next tick applies p2's OnLeave, then suspends in the broadcast sync before its
        // handler.
        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        await transport.arm()
        let tick = Task { await keeper.stepTickOnce() }
        await transport.gate.waitUntilEntered()

        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)
        let shutdown = Task { await keeper.forceShutdown() }
        // The shutdown has stopped new ticks and waits for the suspended one (#382).
        guard await signals.wait(for: "shutdown-stop-gate") else { return }
        #expect(!keeper.isDraining, "the drain flag waits for the shutdown turn")
        // An action taken meanwhile is queued for the next tick (a tick land's response is
        // the queue ACK); the shutdown turn drops it, never applied.
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(typeIdentifier: String(describing: DrainPlainAction.self),
                           payload: AnyCodable(DrainPlainAction(amount: 1))),
            playerID: p1, clientID: c1, sessionID: s1
        )
        #expect(await keeper.pendingItemSequencesForTesting().count == 1)
        transport.gate.release()
        await tick.value
        await shutdown.value
        #expect(await keeper.currentState().total == 0, "the queued action is never applied")

        // The tick ran whole before the destroy handler; no tick or input after it.
        let expected = ["join", "join", "tick", "leave", "tick", "finalize"]
        #expect(await keeper.currentState().log == expected)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == expected)
    }

    @Test("Tickless: an action during OnFinalize's resolver is rejected, not applied after finalize", arguments: [false, true])
    func actionDuringFinalizeResolverIsRejected(inTurn: Bool) async throws {
        let keeper = LandKeeper<DrainTestState>(
            definition: makeDrainDefinition(tick: false, finalizeResolver: true),
            initialState: DrainTestState(),
            autoStartLoops: false,
            transport: inTurn ? DrainInTurnTransport() : nil
        )
        #expect(await keeper.isUsingInTurnSync() == inTurn)
        let gateKey = DeliveryGates.freshKey()
        await keeper.setLandID("drain-finalize:\(gateKey)")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let shutdown = Task { await keeper.forceShutdown() }
        await DeliveryGates.gate(gateKey).waitUntilEntered()

        await expectLandClosed {
            _ = try await keeper.handleActionEnvelope(
                ActionEnvelope(typeIdentifier: String(describing: DrainPlainAction.self),
                               payload: AnyCodable(DrainPlainAction(amount: 5))),
                playerID: p1, clientID: c1, sessionID: s1
            )
        }
        DeliveryGates.gate(gateKey).release()
        await shutdown.value

        let state = await keeper.currentState()
        #expect(state.total == 0)
        #expect(state.log == ["join", "finalize"])
    }

    @Test("Tickless: an action whose resolvers finish after the drain started is rejected at delivery", arguments: [false, true])
    func deliveryAfterDrainStartIsRejected(inTurn: Bool) async throws {
        let keeper = LandKeeper<DrainTestState>(
            definition: makeDrainDefinition(tick: false),
            initialState: DrainTestState(),
            autoStartLoops: false,
            transport: inTurn ? DrainInTurnTransport() : nil
        )
        #expect(await keeper.isUsingInTurnSync() == inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = DeliveryGates.freshKey()
        let held = Task {
            try await keeper.handleActionEnvelope(
                ActionEnvelope(typeIdentifier: String(describing: DrainGatedAction.self),
                               payload: AnyCodable(DrainGatedAction(amount: amount))),
                playerID: p1, clientID: c1, sessionID: s1
            )
        }
        await DeliveryGates.gate(amount).waitUntilEntered()
        await keeper.forceShutdown()

        DeliveryGates.gate(amount).release()
        await expectLandClosed { _ = try await held.value }
        let state = await keeper.currentState()
        #expect(state.total == 0)
        #expect(state.log == ["join", "finalize"])
    }

    @Test("Tick land: an input pending when the drain starts is dropped, not applied")
    func pendingInputIsDroppedAtDrain() async throws {
        let keeper = LandKeeper<DrainTestState>(
            definition: makeDrainDefinition(tick: true),
            initialState: DrainTestState(),
            autoStartLoops: false
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        // Queued for the next tick, which never comes.
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(typeIdentifier: String(describing: DrainPlainAction.self),
                           payload: AnyCodable(DrainPlainAction(amount: 3))),
            playerID: p1, clientID: c1, sessionID: s1
        )
        await keeper.forceShutdown()
        await keeper.stepTickOnce()

        let state = await keeper.currentState()
        #expect(state.total == 0)
        #expect(state.log == ["join", "tick", "finalize"])
    }

    @Test("A leave whose OnLeave resolver is held when another leave empties the land: its OnLeave is dropped, OnFinalize runs last and once")
    func leaveHeldAcrossEmptyDestroy() async throws {
        let transport = DestroyHoldTransport()
        let key = DeliveryGates.freshKey()
        let keeper = await makeLifecycleKeeper(gateKey: key, transport: transport)
        let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")
        try await keeper.join(playerID: heldLeaver, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)

        let leave = Task { try await keeper.leave(playerID: heldLeaver, clientID: c1, sessionID: s1) }
        await DeliveryGates.gate(key).waitUntilEntered()
        // p2's leave empties the land; the destroy timer drains it and finalizes.
        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        await transport.gate.waitUntilEntered()

        DeliveryGates.gate(key).release()
        try await leave.value
        transport.gate.release()

        #expect(await keeper.currentState().log == ["join:held-leaver", "join:p2", "leave:p2", "finalize"])
        #expect(await keeper.inputsSkippedAfterDestroy == 0)
    }

    @Test("A leave whose OnLeave resolver is held across forceShutdown: its OnLeave is dropped, OnFinalize runs last and once")
    func leaveHeldAcrossForceShutdown() async throws {
        let key = DeliveryGates.freshKey()
        let keeper = await makeLifecycleKeeper(gateKey: key)
        try await keeper.join(playerID: heldLeaver, clientID: c1, sessionID: s1)

        let leave = Task { try await keeper.leave(playerID: heldLeaver, clientID: c1, sessionID: s1) }
        await DeliveryGates.gate(key).waitUntilEntered()
        await keeper.forceShutdown()

        DeliveryGates.gate(key).release()
        try await leave.value

        #expect(await keeper.currentState().log == ["join:held-leaver", "finalize"])
        #expect(await keeper.inputsSkippedAfterDestroy == 0)
    }

    @Test("A join whose OnJoin resolver is held across forceShutdown is rejected with landShuttingDown; OnFinalize runs last and once")
    func joinHeldAcrossForceShutdown() async throws {
        let key = DeliveryGates.freshKey()
        let keeper = await makeLifecycleKeeper(gateKey: key)
        let join = Task { try await keeper.join(playerID: heldJoiner, clientID: c1, sessionID: s1) }
        await DeliveryGates.gate(key).waitUntilEntered()
        await keeper.forceShutdown()

        DeliveryGates.gate(key).release()
        do {
            try await join.value
            Issue.record("Expected landShuttingDown")
        } catch let error as JoinError {
            guard case .landShuttingDown = error else {
                Issue.record("Unexpected join error: \(error)")
                return
            }
        }

        #expect(await keeper.currentState().log == ["finalize"])
        #expect(await keeper.inputsSkippedAfterDestroy == 0)
        #expect(await keeper.playerCount() == 0)
    }

    @Test("Legacy tick: a drain waits for every overlapping tick, not only the last to start")
    func drainWaitsForOverlappingTicks() async throws {
        let transport = BroadcastHoldTransport()
        let keeper = LandKeeper<DrainTestState>(
            definition: makeDrainDefinition(tick: true),
            initialState: DrainTestState(),
            autoStartLoops: false,
            transport: transport
        )
        let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()

        // Tick A suspends in the broadcast sync of p2's OnLeave; tick B starts and ends meanwhile.
        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        await transport.arm()
        let tickA = Task { await keeper.stepTickOnce() }
        await transport.gate.waitUntilEntered()
        await keeper.stepTickOnce()

        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)
        let shutdown = Task { await keeper.forceShutdown() }
        guard await signals.wait(for: "shutdown-stop-gate") else { return }
        transport.gate.release()
        await tickA.value
        await shutdown.value

        let log = await keeper.currentState().log
        #expect(log.last == "finalize")
        #expect(log.filter { $0 == "tick" }.count == 3)
        #expect(log.filter { $0 == "finalize" }.count == 1)
    }

    @Test("Tickless: an action held by a freeze when the drain starts gets landClosed instead of hanging")
    func frozenIntakeAcrossDrainIsRejected() async throws {
        let keeper = LandKeeper<DrainTestState>(
            definition: makeDrainDefinition(tick: false),
            initialState: DrainTestState(),
            autoStartLoops: false
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)

        let held = Task {
            try await keeper.handleActionEnvelope(plainAction(7), playerID: p1, clientID: c1, sessionID: s1)
        }
        // The freeze holds the action.
        guard await signals.wait(for: "input-held-frozen") else { return }
        await keeper.forceShutdown()

        try await expectLandClosed("the frozen action returns after the drain starts", held)
        #expect(await keeper.currentState().total == 0)
        #expect(await keeper.currentState().log == ["join", "finalize"])
    }

    @Test("Tickless in-turn: the shutdown waits for the turn in flight; an input queued before it is applied, one after it gets landClosed (#382)")
    func shutdownQueuesBehindPendingInTurnInput() async throws {
        let keeper = LandKeeper<DrainTestState>(
            definition: makeDrainDefinition(tick: false),
            initialState: DrainTestState(),
            autoStartLoops: false,
            transport: DrainInTurnTransport()
        )
        #expect(await keeper.isUsingInTurnSync())
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)

        // A is applied in an input turn whose record is held; B arrives meanwhile and stays
        // pending (the drain loop is suspended at A's record).
        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)
        let recordGate = WatermarkGate()
        await keeper.installHolds(HoldRegistry.at(.turnRecord) { await recordGate.enterAndWait() })
        let applied = Task {
            try await keeper.handleActionEnvelope(plainAction(2), playerID: p1, clientID: c1, sessionID: s1)
        }
        await recordGate.waitUntilEntered()
        let before = Task {
            try await keeper.handleActionEnvelope(plainAction(5), playerID: p1, clientID: c1, sessionID: s1)
        }
        // A was queued before its turn; B is the second.
        guard await signals.wait(for: "action-queued", count: 2) else { return }

        // The shutdown queues behind B; C arrives after it.
        let shutdown = Task { await keeper.forceShutdown() }
        guard await signals.wait(for: "shutdown-queued") else { return }
        let after = Task {
            try await keeper.handleActionEnvelope(plainAction(11), playerID: p1, clientID: c1, sessionID: s1)
        }
        guard await signals.wait(for: "action-queued", count: 3) else { return }
        #expect(await keeper.pendingItemSequencesForTesting().count == 3)
        #expect(!keeper.isDraining, "the shutdown waits for the turn in flight")

        await keeper.installHolds(nil)
        recordGate.release()
        guard try await withinDeadline("the shutdown returns", { await shutdown.value }) != nil else { return }
        try await expectLandClosed("the action queued after the shutdown is dropped by its turn", after)

        for (task, step) in [(applied, "A returns"), (before, "B returns")] {
            guard let response = try await withinDeadline(step, { try await task.value }) else { return }
            let ack = (response.base as? DrainAck) ?? ((response.base as? AnyCodable)?.base as? DrainAck)
            #expect(ack?.ok == true, "\(step) with its response")
        }
        #expect(await keeper.currentState().total == 7)
        #expect(await keeper.currentState().log == ["join", "action", "action", "finalize"])
        #expect(await keeper.playerCount() == 0)
    }
}
