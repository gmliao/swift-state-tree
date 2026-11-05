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

/// Gate key of the OnFinalize resolver: one per land ID, so the cases of the test that uses it
/// never share a gate when they run in parallel.
private func finalizeGateKey(landID: String) -> Int {
    landID == finalizeInTurnLandID ? 9_002 : 9_001
}
private let finalizeInTurnLandID = "drain-test:in-turn"

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
        await DeliveryGates.gate(finalizeGateKey(landID: ctx.landID)).enterAndWait()
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
        includeSync: Bool
    ) -> InTurnSyncResult {
        includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

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

@Suite("Drain as turns", .timeLimit(.minutes(1)))
struct DrainTurnTests {
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

        let shutdown = Task { await keeper.forceShutdown() }
        // The drain has started: input is closed while the tick is still suspended.
        while !keeper.isDraining { await Task.yield() }
        await expectLandClosed {
            _ = try await keeper.handleActionEnvelope(
                ActionEnvelope(typeIdentifier: String(describing: DrainPlainAction.self),
                               payload: AnyCodable(DrainPlainAction(amount: 1))),
                playerID: p1, clientID: c1, sessionID: s1
            )
        }
        transport.gate.release()
        await tick.value
        await shutdown.value

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
        let landID = inTurn ? finalizeInTurnLandID : "drain-test:legacy"
        await keeper.setLandID(landID)
        let gateKey = finalizeGateKey(landID: landID)
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
        let amount = inTurn ? 9_102 : 9_101
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
}
