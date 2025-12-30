import Testing
import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeHummingbird

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
            HandleEvent(TestPingEvent.self) { (state: inout TestGameState, event: TestPingEvent, ctx: LandContext) in
                ctx.spawn {
                    await ctx.sendEvent(TestPongEvent(), to: .session(ctx.sessionID))
                }
            }
            HandleEvent(TestChatEvent.self) { (state: inout TestGameState, event: TestChatEvent, ctx: LandContext) in
                    state.messageCount += 1
                ctx.spawn {
                    await ctx.sendEvent(TestChatMessageEvent(message: event.message), to: .all)
                }
            }
        }
    }
}

@Test("LandServerForTest wires transport and runtime")
func testLandServerForTestHandlesClientEvents() async throws {
    // Arrange
    typealias TestLandServer = LandServer<TestGameState>
    let harness = await TestLandServer.makeForTest(
        land: TestGame.land,
        initialState: TestGameState()
    )
    let connection = RecordingWebSocketConnection()
    let sessionID = SessionID("session-app-container")

    await harness.connect(sessionID: sessionID, using: connection)

    // Join first (required for sending events)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let landID = LandID(harness.land.id)
    let joinMessage = TransportMessage.join(
        requestID: UUID().uuidString,
        landType: landID.landType.isEmpty ? harness.land.id : landID.landType,
        landInstanceId: landID.landType.isEmpty ? nil : landID.instanceId,
        playerID: sessionID.rawValue,
        deviceID: nil,
        metadata: [:]
    )
    let joinData = try encoder.encode(joinMessage)
    await harness.send(joinData, from: sessionID)

    // Wait for join to complete
    try await Task.sleep(nanoseconds: 10_000_000)

    // Act: send ping event
    let pingEvent = AnyClientEvent(TestPingEvent())
    let pingMessage = TransportMessage.event(
        landID: harness.land.id,
        event: .fromClient(event: pingEvent)
    )
    let pingData = try encoder.encode(pingMessage)
    await harness.send(pingData, from: sessionID)

    // Act: send chat event to mutate state
    let chatEvent = AnyClientEvent(TestChatEvent(message: "hello"))
    let chatMessage = TransportMessage.event(
        landID: harness.land.id,
        event: .fromClient(event: chatEvent)
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
        if message.kind == .event,
           case .event(let payload) = message.payload,
           case .fromServer(let anyEvent) = payload.event,
           anyEvent.type == "TestPongEvent" {
            return true
        }
        return false
    }))

    #expect(transportMessages.contains(where: { message in
        if message.kind == .event,
           case .event(let payload) = message.payload,
           case .fromServer(let anyEvent) = payload.event,
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

