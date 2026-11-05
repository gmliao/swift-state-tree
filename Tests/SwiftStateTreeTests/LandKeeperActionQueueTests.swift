// Tests/SwiftStateTreeTests/LandKeeperActionQueueTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test State and Actions

@StateNodeBuilder
struct QueueTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var counter: Int = 0
}

struct QueueIncrementResponse: ResponsePayload {
    static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
}

@Payload
struct QueueIncrementAction: ActionPayload {
    typealias Response = QueueIncrementResponse
    
    func apply(to state: inout QueueTestState, ctx: LandContext) {
        state.counter += 1
    }
}

// MARK: - Tests

private func queueTestLand(tick interval: Duration) -> LandDefinition<QueueTestState> {
    Land("queue-test", using: QueueTestState.self) {
        Rules {
            HandleAction(QueueIncrementAction.self) { (state: inout QueueTestState, action: QueueIncrementAction, ctx: LandContext) in
                action.apply(to: &state, ctx: ctx)
                return QueueIncrementResponse()
            }
        }
        Lifetime {
            Tick(every: interval) { (_: inout QueueTestState, _: LandContext) in }
        }
    }
}

private func sendIncrement(to keeper: LandKeeper<QueueTestState>, as player: PlayerID) async throws {
    let envelope = ActionEnvelope(typeIdentifier: "QueueIncrementAction", payload: AnyCodable(QueueIncrementAction()))
    _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: ClientID("c1"), sessionID: SessionID("s1"))
}

@Test("Action is queued and executed in tick")
func testActionQueuing() async throws {
    // An hourly tick, stepped by hand: no real tick can run between the action and the "still
    // queued" check, which a short real interval allowed (#184).
    let keeper = LandKeeper(definition: queueTestLand(tick: .seconds(3600)), initialState: QueueTestState(), enableLoopPhaseOffset: false)
    let alice = PlayerID("alice")
    try await keeper.join(playerID: alice, clientID: ClientID("c1"), sessionID: SessionID("s1"))

    try await sendIncrement(to: keeper, as: alice)
    #expect(await keeper.currentState().counter == 0, "Counter should be 0 immediately after handleAction (should be queued)")
    #expect(await keeper.pendingItemSequencesForTesting().count == 1)

    await keeper.stepTickOnce()
    #expect(await keeper.currentState().counter == 1, "Counter should be 1 after tick execution")
    #expect(await keeper.pendingItemSequencesForTesting().isEmpty)
}

@Test("Real tick smoke: a queued action is applied by the running tick loop")
func testActionQueuingRealTick() async throws {
    // No "not yet applied" check here: the 50 ms loop may tick at any point.
    let keeper = LandKeeper(definition: queueTestLand(tick: .milliseconds(50)), initialState: QueueTestState(), enableLoopPhaseOffset: false)
    let alice = PlayerID("alice")
    try await keeper.join(playerID: alice, clientID: ClientID("c1"), sessionID: SessionID("s1"))

    try await sendIncrement(to: keeper, as: alice)
    await waitFor("the queued action to run in a tick", timeout: .seconds(2)) {
        await keeper.currentState().counter == 1
    }
    #expect(await keeper.currentState().counter == 1, "Counter should be 1 after tick execution")
}
