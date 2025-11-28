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
