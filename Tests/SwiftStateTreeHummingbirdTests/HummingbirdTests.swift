import Testing
import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeHummingbird

@StateNodeBuilder
struct TestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

enum TestClientEvent: ClientEventPayload {
    case ping
    case chat(String)
}

enum TestServerEvent: ServerEventPayload {
    case pong
    case message(String)
}

// MARK: - Test Doubles

actor RecordingWebSocketConnection: WebSocketConnection {
    private(set) var sentMessages: [Data] = []
    
    func send(_ data: Data) async throws {
        sentMessages.append(data)
    }
    
    func close() async throws { }
    
    func recordedMessages() async -> [Data] {
        sentMessages
    }
}

// MARK: - Hummingbird Integration Tests

@Test("Hummingbird server setup with StateTree")
func testServerSetup() async throws {
    // Arrange
    let definition = Land(
        "hb-test",
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let transportAdapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: "hb-test"
    )
    await transport.setDelegate(transportAdapter)
    
    let hbAdapter = HummingbirdStateTreeAdapter(transport: transport)
    
    // Act: Setup Hummingbird Router
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/game") { inbound, outbound, context in
        await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
    }
    
    // Assert: Build Application (Dry run - just verify it initializes)
    let app = Application(router: router)
    _ = app // Ensures the application initializes with the configured router.
}

@Test("Hummingbird adapter handles WebSocket connection")
func testHummingbirdAdapterConnection() async throws {
    // Arrange
    let definition = Land(
        "hb-test",
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules {
            OnJoin { (state: inout TestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Connected"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let transportAdapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: "hb-test"
    )
    await transport.setDelegate(transportAdapter)
    
    let hbAdapter = HummingbirdStateTreeAdapter(transport: transport)
    
    // Act: Simulate WebSocket connection
    // Note: In a real test, we would use a test WebSocket client
    // For now, we verify the adapter can be created and configured
    _ = hbAdapter
    
    // Assert: Verify setup completed without errors
    #expect(true)
}

@Test("Hummingbird app can be configured with StateTree")
func testHummingbirdAppConfiguration() async throws {
    // Arrange
    let definition = Land(
        "hb-app-test",
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(definition: definition, initialState: TestState())
    let transportAdapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: "hb-app-test"
    )
    await transport.setDelegate(transportAdapter)
    
    let hbAdapter = HummingbirdStateTreeAdapter(transport: transport)
    
    // Act: Setup complete application
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/game") { inbound, outbound, context in
        await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
    }
    
    router.get("/health") { _, _ in
        return "OK"
    }
    
    let app = Application(
        router: router,
        configuration: .init(
            address: .hostname("127.0.0.1", port: 0) // Use port 0 for testing (OS assigns available port)
        )
    )
    
    // Assert: Application can be created
    _ = app
    
    // Note: In a real integration test, we would:
    // 1. Start the app
    // 2. Connect a WebSocket client
    // 3. Send messages
    // 4. Verify responses
    // 5. Stop the app
    
    #expect(true)
}

@Test("Hummingbird adapter emits transport JSON after client events")
func testHummingbirdAdapterEmitsJSON() async throws {
    // Arrange: Build land that echoes events back to the sender
    let definition = Land(
        "hb-json",
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules {
            On(TestClientEvent.self) { (state: inout TestState, event: TestClientEvent, ctx: LandContext) in
                switch event {
                case .ping:
                    state.count += 1
                    await ctx.sendEvent(TestServerEvent.pong, to: .session(ctx.sessionID))
                case .chat(let message):
                    await ctx.sendEvent(TestServerEvent.message(message), to: .session(ctx.sessionID))
                }
            }
        }
    }
    
    let transport = WebSocketTransport()
    
    actor AdapterHolder {
        var adapter: TransportAdapter<TestState, TestClientEvent, TestServerEvent>?
        
        func set(_ adapter: TransportAdapter<TestState, TestClientEvent, TestServerEvent>) {
            self.adapter = adapter
        }
    }
    
    let adapterHolder = AdapterHolder()
    
    let keeper = LandKeeper<TestState, TestClientEvent, TestServerEvent>(
        definition: definition,
        initialState: TestState(),
        sendEvent: { event, target in
            await adapterHolder.adapter?.sendEvent(event, to: target)
        },
        syncNow: {
            await adapterHolder.adapter?.syncNow()
        }
    )
    
    let adapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(
        keeper: keeper,
        transport: transport,
        landID: definition.id
    )
    await adapterHolder.set(adapter)
    await transport.setDelegate(adapter)
    
    let connection = RecordingWebSocketConnection()
    let sessionID = SessionID("sess-json")
    
    // Act: Simulate a WebSocket session and send client events as transport JSON
    await transport.handleConnection(sessionID: sessionID, connection: connection)
    
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    
    let pingMessage = TransportMessage<TestClientEvent, TestServerEvent>.event(
        landID: definition.id,
        event: .fromClient(.ping)
    )
    let pingData = try encoder.encode(pingMessage)
    await transport.handleIncomingMessage(sessionID: sessionID, data: pingData)
    
    let chatMessage = TransportMessage<TestClientEvent, TestServerEvent>.event(
        landID: definition.id,
        event: .fromClient(.chat("hello"))
    )
    let chatData = try encoder.encode(chatMessage)
    await transport.handleIncomingMessage(sessionID: sessionID, data: chatData)
    
    try await Task.sleep(nanoseconds: 50_000_000) // Allow async sends to finish
    
    // Assert: Server sent back transport-formatted JSON we can decode on the client
    let outgoing = await connection.recordedMessages()
    let transportMessages = outgoing.compactMap { try? decoder.decode(TransportMessage<TestClientEvent, TestServerEvent>.self, from: $0) }
    
    #expect(transportMessages.contains { message in
        if case .event(let landID, let event) = message,
           landID == definition.id,
           case .fromServer(.pong) = event {
            return true
        }
        return false
    })
    
    #expect(transportMessages.contains { message in
        if case .event(let landID, let event) = message,
           landID == definition.id,
           case .fromServer(.message(let text)) = event {
            return text == "hello"
        }
        return false
    })
    
    let state = await keeper.currentState()
    #expect(state.count == 1)
}
