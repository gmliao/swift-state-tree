import Testing
import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeHummingbirdHosting

// MARK: - Test Fixtures

@StateNodeBuilder
private struct TestGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var messageCount: Int = 0
    
    init() {}
}

private enum TestClientEvents: ClientEventPayload, Hashable {
    case ping
    case chat(String)
}

private enum TestServerEvents: ServerEventPayload {
    case pong
    case chatMessage(String)
}

private enum TestGame {
    static let land: LandDefinition<TestGameState, TestClientEvents, TestServerEvents> = Land(
        "test-game",
        using: TestGameState.self,
        clientEvents: TestClientEvents.self,
        serverEvents: TestServerEvents.self
    ) {
        Rules {
            On(TestClientEvents.self) { (state: inout TestGameState, event: TestClientEvents, ctx: LandContext) in
                switch event {
                case .ping:
                    await ctx.sendEvent(TestServerEvents.pong, to: .session(ctx.sessionID))
                case .chat(let message):
                    state.messageCount += 1
                    await ctx.sendEvent(TestServerEvents.chatMessage(message), to: .all)
                }
            }
        }
    }
}

@Test("AppContainerForTest wires transport and runtime")
func testAppContainerForTestHandlesClientEvents() async throws {
    // Arrange
    typealias TestAppContainer = AppContainer<TestGameState, TestClientEvents, TestServerEvents>
    let harness = await TestAppContainer.makeForTest(
        land: TestGame.land,
        initialState: TestGameState()
    )
    let connection = RecordingWebSocketConnection()
    let sessionID = SessionID("session-app-container")
    
    await harness.connect(sessionID: sessionID, using: connection)
    
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    
    // Act: send ping event
    let pingMessage = TransportMessage<TestClientEvents, TestServerEvents>.event(
        landID: harness.land.id,
        event: .fromClient(.ping)
    )
    let pingData = try encoder.encode(pingMessage)
    await harness.send(pingData, from: sessionID)
    
    // Act: send chat event to mutate state
    let chatMessage = TransportMessage<TestClientEvents, TestServerEvents>.event(
        landID: harness.land.id,
        event: .fromClient(.chat("hello"))
    )
    let chatData = try encoder.encode(chatMessage)
    await harness.send(chatData, from: sessionID)
    
    try await Task.sleep(nanoseconds: 50_000_000)
    
    // Assert: transport echoed server events via adapter
    let outgoing = await connection.recordedMessages()
    let transportMessages = outgoing.compactMap {
        try? decoder.decode(TransportMessage<TestClientEvents, TestServerEvents>.self, from: $0)
    }
    
    #expect(transportMessages.contains(where: { message in
        if case .event(_, let payload) = message,
           case .fromServer(.pong) = payload {
            return true
        }
        return false
    }))
    
    #expect(transportMessages.contains(where: { message in
        if case .event(_, let payload) = message,
           case .fromServer(.chatMessage(let text)) = payload {
            return text == "hello"
        }
        return false
    }))
    
    let state = await harness.keeper.currentState()
    #expect(state.messageCount == 1)
}

