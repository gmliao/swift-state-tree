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

@Payload
private struct TestPingEvent: ClientEventPayload {
    public init() {}
}

@Payload
private struct TestChatEvent: ClientEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
}

@Payload
private struct TestPongEvent: ServerEventPayload {
    public init() {}
}

@Payload
private struct TestChatMessageEvent: ServerEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
}

private enum TestGame {
    static let land: LandDefinition<TestGameState> = Land(
        "test-game",
        using: TestGameState.self
    ) {
        ClientEvents {
            Register(TestPingEvent.self)
            Register(TestChatEvent.self)
        }
        ServerEvents {
            Register(TestPongEvent.self)
            Register(TestChatMessageEvent.self)
        }
        Rules {
            On(TestPingEvent.self) { (state: inout TestGameState, event: TestPingEvent, ctx: LandContext) in
                await ctx.sendEvent(TestPongEvent(), to: .session(ctx.sessionID))
            }
            On(TestChatEvent.self) { (state: inout TestGameState, event: TestChatEvent, ctx: LandContext) in
                    state.messageCount += 1
                await ctx.sendEvent(TestChatMessageEvent(message: event.message), to: .all)
            }
        }
    }
}

@Test("AppContainerForTest wires transport and runtime")
func testAppContainerForTestHandlesClientEvents() async throws {
    // Arrange
    typealias TestAppContainer = AppContainer<TestGameState>
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
    let pingEvent = AnyClientEvent(TestPingEvent())
    let pingMessage = TransportMessage.event(
        landID: harness.land.id,
        event: .fromClient(pingEvent)
    )
    let pingData = try encoder.encode(pingMessage)
    await harness.send(pingData, from: sessionID)
    
    // Act: send chat event to mutate state
    let chatEvent = AnyClientEvent(TestChatEvent(message: "hello"))
    let chatMessage = TransportMessage.event(
        landID: harness.land.id,
        event: .fromClient(chatEvent)
    )
    let chatData = try encoder.encode(chatMessage)
    await harness.send(chatData, from: sessionID)
    
    try await Task.sleep(nanoseconds: 50_000_000)
    
    // Assert: transport echoed server events via adapter
    let outgoing = await connection.recordedMessages()
    let transportMessages = outgoing.compactMap {
        try? decoder.decode(TransportMessage.self, from: $0)
    }
    
    #expect(transportMessages.contains(where: { message in
        if case .event(_, let eventWrapper) = message,
           case .fromServer(let anyEvent) = eventWrapper,
           anyEvent.type == "TestPongEvent" {
            return true
        }
        return false
    }))
    
    #expect(transportMessages.contains(where: { message in
        if case .event(_, let eventWrapper) = message,
           case .fromServer(let anyEvent) = eventWrapper,
           anyEvent.type == "TestChatMessageEvent" {
            // Decode the payload to check message content
            if let payloadDict = anyEvent.payload.base as? [String: Any],
               let message = payloadDict["message"] as? String,
               message == "hello" {
                return true
            }
        }
        return false
    }))
    
    let state = await harness.keeper.currentState()
    #expect(state.messageCount == 1)
}

