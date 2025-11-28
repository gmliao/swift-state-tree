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
}

enum TestClientEvent: ClientEventPayload {
    case ping
}

enum TestServerEvent: ServerEventPayload {
    case pong
}

@Test("Hummingbird server setup with StateTree")
func testServerSetup() async throws {
    // 1. Setup Land
    let definition = Land(
        "hb-test",
        using: TestState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self
    ) {
        Rules { }
    }
    
    let keeper = LandKeeper(definition: definition, initialState: TestState())
    let transportAdapter = TransportAdapter<TestState, TestClientEvent, TestServerEvent>(keeper: keeper)
    let transport = WebSocketTransport()
    await transport.setDelegate(transportAdapter)
    
    let hbAdapter = HummingbirdStateTreeAdapter(transport: transport)
    
    // 2. Setup Hummingbird Router
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/game") { inbound, outbound, context in
        await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
    }
    
    // 3. Build Application (Dry run)
    let app = Application(router: router)
    _ = app // Ensures the application initializes with the configured router.
}
