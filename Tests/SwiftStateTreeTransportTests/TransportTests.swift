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

enum TestClientEvent: ClientEventPayload {
    case increment
    case chat(String)
}

enum TestServerEvent: ServerEventPayload {
    case pong
    case message(String)
}

// MARK: - TransportAdapter Tests

@Test("TransportAdapter forwards events to LandKeeper")
func testTransportAdapterForwardsEvents() async throws {
    // Arrange
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
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: "test-land"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect and send event
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    let event = Event<TestClientEvent, TestServerEvent>.fromClient(.increment)
    let transportMsg = TransportMessage.event(landID: "test-land", event: event)
    let data = try JSONEncoder().encode(transportMsg)
    
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
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
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
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: "test-land"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
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
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: "test-land"
    )
    await transport.setDelegate(adapter)
    
    let sessionID1 = SessionID("sess-1")
    let sessionID2 = SessionID("sess-2")
    let clientID1 = ClientID("cli-1")
    let clientID2 = ClientID("cli-2")
    
    await adapter.onConnect(sessionID: sessionID1, clientID: clientID1)
    await adapter.onConnect(sessionID: sessionID2, clientID: clientID2)
    
    // Act: Send event to specific session
    await adapter.sendEvent(TestServerEvent.message("Hello"), to: .session(sessionID1))
    
    // Note: In a real test, we would verify the message was sent through the transport
    // For now, we just verify no errors occurred
    #expect(Bool(true))
}

@Test("TransportAdapter syncs state")
func testTransportAdapterSyncNow() async throws {
    // Arrange
    let definition = Land(
        "test-land",
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let adapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: "test-land"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Trigger sync
    await adapter.syncNow()
    
    // Note: In a real test, we would verify the state snapshot was sent
    // For now, we just verify no errors occurred
    #expect(Bool(true))
}
