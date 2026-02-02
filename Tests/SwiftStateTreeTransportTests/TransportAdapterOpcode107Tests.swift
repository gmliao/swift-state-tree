import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct Opcode107TestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

@Payload
struct Opcode107IncrementEvent: ClientEventPayload {
    public init() {}
}

@Payload
struct Opcode107MessageEvent: ServerEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
}

actor Opcode107RecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var sentMessages: [Data] = []

    func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    func start() async throws { }
    func stop() async throws { }

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sentMessages.append(message)
    }

    func recordedMessages() async -> [Data] {
        sentMessages
    }

    func clearMessages() async {
        sentMessages.removeAll()
    }
}

@Test("TransportAdapter only merges broadcast events into opcode 107")
func testTransportAdapterOnlyMergesBroadcastEventsIntoOpcode107() async throws {
    let definition = Land(
        "opcode107-test",
        using: Opcode107TestState.self
    ) {
        ClientEvents {
            Register(Opcode107IncrementEvent.self)
        }
        ServerEvents {
            Register(Opcode107MessageEvent.self)
        }
        Rules {
            HandleEvent(Opcode107IncrementEvent.self) { (state: inout Opcode107TestState, _: Opcode107IncrementEvent, _) in
                state.count += 1
            }
        }
    }

    let transport = Opcode107RecordingTransport()
    let keeper = LandKeeper<Opcode107TestState>(definition: definition, initialState: Opcode107TestState())
    let encodingConfig = TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
    let adapter = TransportAdapter<Opcode107TestState>(
        keeper: keeper,
        transport: transport,
        landID: "opcode107-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)

    let sessionID = SessionID("sess-107")
    let clientID = ClientID("cli-107")
    let playerID = PlayerID("player-107")

    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: sessionID,
        clientID: clientID,
        playerID: playerID
    )
    await transport.clearMessages()

    let clientEvent = AnyClientEvent(Opcode107IncrementEvent())
    let clientMessage = TransportMessage.event(event: .fromClient(event: clientEvent))
    let encoder = MessagePackTransportMessageEncoder()
    let clientData = try encoder.encode(clientMessage)
    await adapter.onMessage(clientData, from: sessionID)
    try await Task.sleep(for: .milliseconds(50))

    let serverEvent = AnyServerEvent(Opcode107MessageEvent(message: "hello"))
    await adapter.sendEvent(serverEvent, to: .client(clientID))

    await adapter.syncNow()

    let messages = await transport.recordedMessages()
    #expect(messages.count == 2, "Expected broadcast update + targeted event")

    var opcode107Count = 0
    var opcode103Count = 0
    var opcode107EventCount: Int?

    for message in messages {
        let unpacked = try unpack(message)
        guard case .array(let array) = unpacked else {
            Issue.record("Expected MessagePack array payload")
            continue
        }
        guard case .int(let opcode) = array.first else {
            Issue.record("Expected opcode as first element")
            continue
        }

        switch opcode {
        case 107:
            opcode107Count += 1
            if array.count >= 3, case .array(let events) = array[2] {
                opcode107EventCount = events.count
            }
        case 103:
            opcode103Count += 1
        default:
            Issue.record("Unexpected opcode \(opcode)")
        }
    }

    #expect(opcode107Count == 1, "Expected one opcode 107 broadcast update")
    #expect(opcode103Count == 1, "Expected one standalone event frame")
    #expect(opcode107EventCount == 0, "Expected no merged targeted events")
}

@Test("TransportAdapter sends event as separate frame when opcode 107 is on but message encoder is JSON (encodeServerEventBody returns nil)")
func testSendEventFallbackWhenBodyEncodingFails() async throws {
    // Hybrid config: state update is opcodeMessagePack (so useStateUpdateWithEvents = true),
    // but message encoder is JSON. encodeServerEventBody then returns nil (JSON bytes can't be MessagePack-unpacked).
    // We must fall back to sending the event as a separate frame instead of dropping it.
    let definition = Land(
        "opcode107-fallback-test",
        using: Opcode107TestState.self
    ) {
        ClientEvents {
            Register(Opcode107IncrementEvent.self)
        }
        ServerEvents {
            Register(Opcode107MessageEvent.self)
        }
        Rules {
            HandleEvent(Opcode107IncrementEvent.self) { (state: inout Opcode107TestState, _: Opcode107IncrementEvent, _) in
                state.count += 1
            }
        }
    }

    let transport = Opcode107RecordingTransport()
    let keeper = LandKeeper<Opcode107TestState>(definition: definition, initialState: Opcode107TestState())
    let encodingConfig = TransportEncodingConfig(message: .json, stateUpdate: .opcodeMessagePack)
    let adapter = TransportAdapter<Opcode107TestState>(
        keeper: keeper,
        transport: transport,
        landID: "opcode107-fallback-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)

    let sessionID = SessionID("sess-fallback")
    let clientID = ClientID("cli-fallback")
    let playerID = PlayerID("player-fallback")

    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: sessionID,
        clientID: clientID,
        playerID: playerID
    )
    await transport.clearMessages()

    let serverEvent = AnyServerEvent(Opcode107MessageEvent(message: "fallback-test"))
    await adapter.sendEvent(serverEvent, to: .client(clientID))

    let messages = await transport.recordedMessages()
    var foundEventFrame = false
    for message in messages {
        guard let obj = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let kind = obj["kind"] as? String, kind == "event" else {
            continue
        }
        foundEventFrame = true
        break
    }
    #expect(foundEventFrame, "Event must be sent as a separate JSON frame when body encoding fails (no silent drop)")
}
