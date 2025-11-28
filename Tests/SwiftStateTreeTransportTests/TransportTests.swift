import Testing
import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct TestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

enum TestClientEvent: ClientEventPayload {
    case increment
}

enum TestServerEvent: ServerEventPayload {
    case pong
}

@Test("TransportAdapter forwards events to LandKeeper")
func testTransportAdapter() async throws {
    // 1. Setup Land
    let definition = Land(
        "test-land",
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules {
            On(TestClientEvent.self) { (state: inout TestState, event: TestClientEvent, _) in
                if case .increment = event {
                    state.count += 1
                }
            }
        }
    }
    
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(keeper: keeper)
    
    // 2. Simulate incoming message
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Join first (needed for event handling usually, but handleClientEvent might work if we bypass checks or if we join first)
    // Let's join first to be safe
    await keeper.join(playerID: PlayerID("guest-sess-1"), clientID: clientID, sessionID: sessionID)
    
    let event = Event<TestClientEvent, TestServerEvent>.fromClient(.increment)
    let transportMsg = TransportMessage.event(landID: "test-land", event: event)
    let data = try JSONEncoder().encode(transportMsg)
    
    // 3. Send message through adapter
    await adapter.onMessage(data, from: sessionID)
    
    // 4. Verify state change
    let state = await keeper.currentState()
    #expect(state.count == 1)
}
