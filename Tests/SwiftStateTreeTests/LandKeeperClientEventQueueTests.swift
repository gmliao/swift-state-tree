// Tests/SwiftStateTreeTests/LandKeeperClientEventQueueTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ClientEventQueueTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    @Sync(.broadcast)
    var totalCookies: Int = 0
}

@Payload
struct ClickCookieEvent: ClientEventPayload {
    let amount: Int
}

@Test("Client event executes on tick when tick handler is configured")
func testClientEventQueuedUntilTick() async throws {
    let definition = Land("client-event-queue-test", using: ClientEventQueueTestState.self) {
        ClientEvents {
            Register(ClickCookieEvent.self)
        }

        Rules {
            HandleEvent(ClickCookieEvent.self) { (state: inout ClientEventQueueTestState, event: ClickCookieEvent, _: LandContext) in
                state.totalCookies += event.amount
            }
        }

        Lifetime {
            Tick(every: .milliseconds(200)) { (state: inout ClientEventQueueTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }

    let keeper = LandKeeper(definition: definition, initialState: ClientEventQueueTestState())
    let playerID = PlayerID("alice")
    let clientID = ClientID("c1")
    let sessionID = SessionID("s1")

    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let event = AnyClientEvent(ClickCookieEvent(amount: 5))
    try await keeper.handleClientEvent(event, playerID: playerID, clientID: clientID, sessionID: sessionID)

    // Before first tick, event should not be applied yet.
    let stateBeforeTick = await keeper.currentState()
    #expect(stateBeforeTick.totalCookies == 0, "Event should be queued until the next tick")

    // Wait for at least one tick to fire.
    try await Task.sleep(for: .milliseconds(300))

    let stateAfterTick = await keeper.currentState()
    #expect(stateAfterTick.totalCookies == 5, "Event should be applied during tick processing")
    #expect(stateAfterTick.ticks >= 1, "Tick handler should have executed at least once")
}
