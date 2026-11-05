// Tests/SwiftStateTreeTests/PerSequenceResultTests.swift
//
// Tickless callers get their own input's outcome (#88), on the legacy path (in-turn sync off)
// and the in-turn path alike: a pass that applies several callers' inputs no longer returns
// the last one's response to whoever ran it, and the inputs applied before a throwing input
// are not applied again.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct PerSequenceTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    /// How many more times each throwing action (by tag) throws before it applies.
    @Sync(.broadcast)
    var failuresLeft: [String: Int] = [:]

    public init() {}
}

@Payload
struct PerSequenceAck: ResponsePayload {
    let amount: Int
}

@Payload
struct PerSequencePlainAction: ActionPayload {
    typealias Response = PerSequenceAck
    let amount: Int
}

@Payload
struct PerSequenceGatedAction: ActionPayload {
    typealias Response = PerSequenceAck
    /// Also the key of the resolver's gate (`DeliveryGates`).
    let amount: Int
}

@Payload
struct PerSequenceThrowingAction: ActionPayload {
    typealias Response = PerSequenceAck
    let amount: Int
    /// Key into `failuresLeft`.
    let tag: String
}

struct PerSequenceGatedResolver: ContextResolver {
    typealias Output = DeliveryResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> DeliveryResolverOutput {
        let amount = (ctx.actionPayload as? PerSequenceGatedAction)?.amount ?? -1
        await DeliveryGates.gate(amount).enterAndWait()
        return DeliveryResolverOutput(value: amount)
    }
}

private struct PerSequenceHandlerFailure: Error {}

private func makePerSequenceDefinition() -> LandDefinition<PerSequenceTestState> {
    Land("per-sequence-test", using: PerSequenceTestState.self) {
        Rules {
            HandleAction(PerSequencePlainAction.self) {
                (state: inout PerSequenceTestState, action: PerSequencePlainAction, _: LandContext) in
                state.total += action.amount
                return PerSequenceAck(amount: action.amount)
            }
            HandleAction(PerSequenceGatedAction.self, resolvers: PerSequenceGatedResolver.self) {
                (state: inout PerSequenceTestState, action: PerSequenceGatedAction, _: LandContext) in
                state.total += action.amount
                return PerSequenceAck(amount: action.amount)
            }
            HandleAction(PerSequenceThrowingAction.self) {
                (state: inout PerSequenceTestState, action: PerSequenceThrowingAction, _: LandContext) in
                if let left = state.failuresLeft[action.tag], left > 0 {
                    state.failuresLeft[action.tag] = left - 1
                    throw PerSequenceHandlerFailure()
                }
                state.total += action.amount
                return PerSequenceAck(amount: action.amount)
            }
        }
    }
}

/// Reports in-turn sync for every keeper and commits each requested sync phase, so a keeper
/// attached to it takes the in-turn path whatever `IN_TURN_SYNC` says. Not an actor: its
/// synchronous calls need no isolation.
private final class PerSequenceInTurnTransport: LandKeeperTransport, @unchecked Sendable {
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

private func makePerSequenceKeeper(
    inTurn: Bool,
    failuresLeft: [String: Int]
) async -> LandKeeper<PerSequenceTestState> {
    var initial = PerSequenceTestState()
    initial.failuresLeft = failuresLeft
    let keeper = LandKeeper<PerSequenceTestState>(
        definition: makePerSequenceDefinition(),
        initialState: initial,
        autoStartLoops: false,
        transport: inTurn ? PerSequenceInTurnTransport() : nil
    )
    #expect(await keeper.isUsingInTurnSync() == inTurn)
    return keeper
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")

private func envelope<A: ActionPayload>(_ action: A) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: A.self), payload: AnyCodable(action))
}

/// The ack in a tickless action's response.
private func ackAmount(_ response: AnyCodable) -> Int? {
    let ack = (response.base as? PerSequenceAck) ?? ((response.base as? AnyCodable)?.base as? PerSequenceAck)
    return ack?.amount
}

private func send<A: ActionPayload>(
    _ keeper: LandKeeper<PerSequenceTestState>,
    _ action: A,
    from player: PlayerID = p1
) async throws -> AnyCodable {
    let (client, session) = player == p1 ? (c1, s1) : (c2, s2)
    return try await keeper.handleActionEnvelope(envelope(action), playerID: player, clientID: client, sessionID: session)
}

private func expectHandlerFailure<A: ActionPayload>(
    _ keeper: LandKeeper<PerSequenceTestState>,
    _ action: A,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        _ = try await send(keeper, action)
        Issue.record("Expected the handler to throw", sourceLocation: sourceLocation)
    } catch {
        #expect(error is PerSequenceHandlerFailure, "unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Tickless callers get their own input's outcome", .timeLimit(.minutes(1)))
struct PerSequenceResultTests {
    @Test("A caller whose pass also applies a later-numbered input gets its own response (#88)", arguments: [false, true])
    func ownResponseWhenPassAppliesLaterInput(inTurn: Bool) async throws {
        let keeper = await makePerSequenceKeeper(inTurn: inTurn, failuresLeft: ["t": 1])
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let gateKey = inTurn ? 8_802 : 8_801

        // Y takes its number, then holds in its resolver.
        let y = Task { try await send(keeper, PerSequenceGatedAction(amount: gateKey), from: p2) }
        guard try await withinDeadline("Y's resolver holds", {
            await DeliveryGates.gate(gateKey).waitUntilEntered()
        }) != nil else { return }

        // T, numbered after Y, throws once and stays pending.
        await expectHandlerFailure(keeper, PerSequenceThrowingAction(amount: 7, tag: "t"))

        // Y's delivery runs Y and then T in one pass (or turn): Y's caller gets Y's response.
        DeliveryGates.gate(gateKey).release()
        guard let response = try await withinDeadline("Y returns", { try await y.value }) else { return }
        #expect(ackAmount(response) == gateKey)
        #expect(await keeper.currentState().total == gateKey + 7)
    }

    @Test("The inputs applied before a throwing input are removed, not applied again", arguments: [false, true])
    func appliedPrefixIsNotReapplied(inTurn: Bool) async throws {
        let keeper = await makePerSequenceKeeper(inTurn: inTurn, failuresLeft: ["w": 2, "t": 1])
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)

        // W throws in its own pass and stays pending; X's pass throws at W again, so X stays
        // pending behind it.
        await expectHandlerFailure(keeper, PerSequenceThrowingAction(amount: 1, tag: "w"))
        await expectHandlerFailure(keeper, PerSequencePlainAction(amount: 5))
        // T's pass applies W and X, then throws at T: W and X are done.
        await expectHandlerFailure(keeper, PerSequenceThrowingAction(amount: 100, tag: "t"))
        // Y's pass applies T and Y only.
        let response = try await send(keeper, PerSequencePlainAction(amount: 7))

        #expect(ackAmount(response) == 7)
        #expect(await keeper.currentState().total == 1 + 5 + 100 + 7)
    }

    @Test("The legacy and in-turn paths give the same responses and state for the same inputs")
    func legacyAndInTurnAgree() async throws {
        var outcomes: [[String]] = []
        for inTurn in [false, true] {
            let keeper = await makePerSequenceKeeper(inTurn: inTurn, failuresLeft: ["w": 2, "t": 1])
            try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
            var log: [String] = []
            let actions: [any ActionPayload] = [
                PerSequencePlainAction(amount: 3),
                PerSequenceThrowingAction(amount: 1, tag: "w"),
                PerSequencePlainAction(amount: 5),
                PerSequenceThrowingAction(amount: 100, tag: "t"),
                PerSequencePlainAction(amount: 7),
                PerSequencePlainAction(amount: 11),
            ]
            for action in actions {
                do {
                    let response = try await keeper.handleActionEnvelope(
                        ActionEnvelope(typeIdentifier: String(describing: type(of: action)), payload: AnyCodable(action)),
                        playerID: p1, clientID: c1, sessionID: s1
                    )
                    log.append("ok \(ackAmount(response).map(String.init) ?? "nil")")
                } catch {
                    log.append("threw")
                }
            }
            log.append("total \(await keeper.currentState().total)")
            outcomes.append(log)
        }
        #expect(outcomes[0] == outcomes[1])
        #expect(outcomes[0] == ["ok 3", "threw", "threw", "threw", "ok 7", "ok 11", "total 127"])
    }
}
