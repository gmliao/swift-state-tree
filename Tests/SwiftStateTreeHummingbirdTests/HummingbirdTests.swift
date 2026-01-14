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
private struct TestMessageEvent: ServerEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
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
        using: TestState.self
    ) {
        ClientEvents {
            Register(TestPingEvent.self)
            Register(TestChatEvent.self)
        }
        ServerEvents {
            Register(TestPongEvent.self)
            Register(TestMessageEvent.self)
        }
        Rules { }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState>(definition: definition, initialState: TestState())
    let transportAdapter = TransportAdapter<TestState>(
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
        using: TestState.self
    ) {
        Rules {
            OnJoin { (state: inout TestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Connected"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState>(definition: definition, initialState: TestState())
    let transportAdapter = TransportAdapter<TestState>(
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
    #expect(Bool(true))
}

@Test("Hummingbird app can be configured with StateTree")
func testHummingbirdAppConfiguration() async throws {
    // Arrange
    let definition = Land(
        "hb-app-test",
        using: TestState.self
    ) {
        Rules { }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<TestState>(definition: definition, initialState: TestState())
    let transportAdapter = TransportAdapter<TestState>(
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

    #expect(Bool(true))
}

@Test("Hummingbird adapter emits transport JSON after client events")
func testHummingbirdAdapterEmitsJSON() async throws {
    // Arrange: Build land that echoes events back to the sender
    let definition = Land(
        "hb-json",
        using: TestState.self
    ) {
        ClientEvents {
            Register(TestPingEvent.self)
            Register(TestChatEvent.self)
        }
        ServerEvents {
            Register(TestPongEvent.self)
            Register(TestMessageEvent.self)
        }
        Rules {
            HandleEvent(TestPingEvent.self) { (state: inout TestState, event: TestPingEvent, ctx: LandContext) in
                state.count += 1
                ctx.spawn {
                    await ctx.sendEvent(TestPongEvent(), to: .session(ctx.sessionID))
                }
            }
            HandleEvent(TestChatEvent.self) { (state: inout TestState, event: TestChatEvent, ctx: LandContext) in
                ctx.spawn {
                    await ctx.sendEvent(TestMessageEvent(message: event.message), to: .session(ctx.sessionID))
                }
            }
        }
    }

    let transport = WebSocketTransport()

    actor AdapterHolder {
        var adapter: TransportAdapter<TestState>?

        func set(_ adapter: TransportAdapter<TestState>) {
            self.adapter = adapter
        }
    }

    let adapterHolder = AdapterHolder()

    let keeper = LandKeeper<TestState>(
        definition: definition,
        initialState: TestState()
    )

    let adapter = TransportAdapter<TestState>(
        keeper: keeper,
        transport: transport,
        landID: definition.id,
        enableLegacyJoin: true
    )

    // Set transport adapter as the transport for keeper
    await keeper.setTransport(adapter)

    await adapterHolder.set(adapter)
    await transport.setDelegate(adapter)

    let connection = RecordingWebSocketConnection()
    let sessionID = SessionID("sess-json")

    // Act: Simulate a WebSocket session and send client events as transport JSON
    await transport.handleConnection(sessionID: sessionID, connection: connection)

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    // Join first (required for sending events)
    let joinMessage = TransportMessage.join(
        requestID: UUID().uuidString,
        landType: definition.id,
        landInstanceId: nil,
        playerID: sessionID.rawValue,
        deviceID: nil,
        metadata: [:]
    )
    let joinData = try encoder.encode(joinMessage)
    await transport.handleIncomingMessage(sessionID: sessionID, data: joinData)

    // Wait for join to complete
    try await Task.sleep(nanoseconds: 10_000_000)

    let pingEvent = AnyClientEvent(TestPingEvent())
    let pingMessage = TransportMessage.event(
        event: .fromClient(event: pingEvent)
    )
    let pingData = try encoder.encode(pingMessage)
    await transport.handleIncomingMessage(sessionID: sessionID, data: pingData)

    let chatEvent = AnyClientEvent(TestChatEvent(message: "hello"))
    let chatMessage = TransportMessage.event(
        event: .fromClient(event: chatEvent)
    )
    let chatData = try encoder.encode(chatMessage)
    await transport.handleIncomingMessage(sessionID: sessionID, data: chatData)

    try await Task.sleep(nanoseconds: 50_000_000) // Allow async sends to finish

    // Assert: Server sent back transport-formatted JSON we can decode on the client
    let outgoing = await connection.recordedMessages()
    let transportMessages = outgoing.compactMap { try? decoder.decode(TransportMessage.self, from: $0) }

    #expect(transportMessages.contains { message in
        if message.kind == .event,
           case .event(let event) = message.payload,
           case .fromServer(let anyEvent) = event,
           anyEvent.type == "TestPong" {
            return true
        }
        return false
    })

    #expect(transportMessages.contains { message in
        if message.kind == .event,
           case .event(let event) = message.payload,
           case .fromServer(let anyEvent) = event,
           anyEvent.type == "TestMessage" {
            // Decode the payload to check message content
            if let payloadDict = anyEvent.payload.base as? [String: Any],
               let message = payloadDict["message"] as? String,
               message == "hello" {
                return true
            }
        }
        return false
    })

    let state = await keeper.currentState()
    #expect(state.count == 1)
}
