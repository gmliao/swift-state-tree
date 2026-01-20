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

@Test("Action is queued and executed in tick")
func testActionQueuing() async throws {
    let definition = Land("queue-test", using: QueueTestState.self) {
        Rules {
            HandleAction(QueueIncrementAction.self) { (state: inout QueueTestState, action: QueueIncrementAction, ctx: LandContext) in
                action.apply(to: &state, ctx: ctx)
                return QueueIncrementResponse()
            }
        }
        Lifetime {
            // Short tick interval for testing
            Tick(every: .milliseconds(50)) { (_: inout QueueTestState, _: LandContext) in }
        }
    }

    let keeper = LandKeeper(definition: definition, initialState: QueueTestState())
    let alice = PlayerID("alice")
    try await keeper.join(playerID: alice, clientID: ClientID("c1"), sessionID: SessionID("s1"))

    // Send action
    let action = QueueIncrementAction()
    let envelope = ActionEnvelope(
        typeIdentifier: "QueueIncrementAction",
        payload: AnyCodable(action)
    )
    _ = try await keeper.handleActionEnvelope(
        envelope,
        playerID: alice,
        clientID: ClientID("c1"),
        sessionID: SessionID("s1")
    )
    
    // State should NOT be updated yet (if queuing is implemented)
    // Currently (without queuing), this will be 1, so the test will fail as expected.
    let stateAfterAction = await keeper.currentState()
    #expect(stateAfterAction.counter == 0, "Counter should be 0 immediately after handleAction (should be queued)")

    // Wait for tick
    try await Task.sleep(for: .milliseconds(100))

    // State SHOULD be updated now
    let stateAfterTick = await keeper.currentState()
    #expect(stateAfterTick.counter == 1, "Counter should be 1 after tick execution")
}
