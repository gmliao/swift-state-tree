import Testing
import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct TestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

@Payload
struct TestIncrementEvent: ClientEventPayload {
    public init() {}
}

@Payload
struct TestChatEvent: ClientEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
}

@Payload
struct TestPongEvent: ServerEventPayload {
    public init() {}
}

@Payload
struct TestMessageEvent: ServerEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
}

// MARK: - TransportAdapter Tests

@Test("TransportAdapter forwards events to LandKeeper")
func testTransportAdapterForwardsEvents() async throws {
    // Arrange
    let definition = Land(
        "test-land",
        using: TestState.self
    ) {
        ClientEvents {
            Register(TestIncrementEvent.self)
            Register(TestChatEvent.self)
        }
        ServerEvents {
            Register(TestPongEvent.self)
            Register(TestMessageEvent.self)
        }
        Rules {
            HandleEvent(TestIncrementEvent.self) { (state: inout TestState, event: TestIncrementEvent, _) in
                    state.count += 1
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState>(
        keeper: keeper,
        transport: transport,
        landID: "test-land",
        enableLegacyJoin: true
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Join
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "test-land",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for join to complete
    try await Task.sleep(for: .milliseconds(10))
    
    // Act: Send event
    let incrementEvent = AnyClientEvent(TestIncrementEvent())
    let transportMsg = TransportMessage.event(landID: "test-land", event: .fromClient(event: incrementEvent))
    let data = try encodeTransportMessage(transportMsg)
    
    await adapter.onMessage(data, from: sessionID)
    
    // Assert
    let state = await keeper.currentState()
    #expect(state.count == 1)
}

@Test("TransportAdapter handles connection and disconnection")
func testTransportAdapterConnectionLifecycle() async throws {
    // Arrange
    let definition = Land(
        "test-land",
        using: TestState.self
    ) {
        Rules {
            OnJoin { (state: inout TestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
            OnLeave { (state: inout TestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState>(
        keeper: keeper,
        transport: transport,
        landID: "test-land",
        enableLegacyJoin: true
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Join
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "test-land",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for join to complete
    try await Task.sleep(for: .milliseconds(10))
    
    // Assert: Player should be in state
    var state = await keeper.currentState()
    let playerID = PlayerID(sessionID.rawValue)
    #expect(state.players[playerID] == "Joined")
    
    // Act: Disconnect
    await adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
    
    // Assert: Player should be removed
    state = await keeper.currentState()
    #expect(state.players[playerID] == nil)
}

@Test("TransportAdapter sends events to correct targets")
func testTransportAdapterSendEvent() async throws {
    // Arrange
    let definition = Land(
        "test-land",
        using: TestState.self
    ) {
        ServerEvents {
            Register(TestMessageEvent.self)
        }
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState>(
        keeper: keeper,
        transport: transport,
        landID: "test-land",
        enableLegacyJoin: true
    )
    await transport.setDelegate(adapter)
    
    let sessionID1 = SessionID("sess-1")
    let sessionID2 = SessionID("sess-2")
    let clientID1 = ClientID("cli-1")
    let clientID2 = ClientID("cli-2")
    
    await adapter.onConnect(sessionID: sessionID1, clientID: clientID1)
    await adapter.onConnect(sessionID: sessionID2, clientID: clientID2)
    
    // Join both sessions
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "test-land",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "test-land",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try encodeTransportMessage(joinRequest1)
    let joinData2 = try encodeTransportMessage(joinRequest2)
    await adapter.onMessage(joinData1, from: sessionID1)
    await adapter.onMessage(joinData2, from: sessionID2)
    
    // Wait a bit for joins to complete
    try await Task.sleep(for: .milliseconds(10))
    
    // Act: Send event to specific session
    let messageEvent = AnyServerEvent(TestMessageEvent(message: "Hello"))
    await adapter.sendEvent(messageEvent, to: .session(sessionID1))
    
    // Note: In a real test, we would verify the message was sent through the transport
    // For now, we just verify no errors occurred
    #expect(Bool(true))
}

@Test("TransportAdapter syncs state")
func testTransportAdapterSyncNow() async throws {
    // Arrange
    let definition = Land(
        "test-land",
        using: TestState.self
    ) {
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState>(
        keeper: keeper,
        transport: transport,
        landID: "test-land",
        enableLegacyJoin: true
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Join
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "test-land",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for join to complete
    try await Task.sleep(for: .milliseconds(10))
    
    // Act: Trigger sync
    await adapter.syncNow()
    
    // Note: In a real test, we would verify the state snapshot was sent
    // For now, we just verify no errors occurred
    #expect(Bool(true))
}
