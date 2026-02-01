import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct MembershipTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var tick: Int = 0
}

@Payload
private struct MembershipMessageEvent: ServerEventPayload {
    let message: String
    init(message: String) { self.message = message }
}

private actor MembershipRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [Data] = []

    func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    func start() async throws { }
    func stop() async throws { }

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) async throws {
        sent.append(message)
    }

    func recordedMessages() async -> [Data] {
        sent
    }

    func clear() async {
        sent.removeAll()
    }
}

@Test("Queued targeted event is dropped after leave + rejoin")
func testQueuedTargetedEventDroppedAfterRejoin() async throws {
    let definition = Land("membership-test", using: MembershipTestState.self) {
        ServerEvents {
            Register(MembershipMessageEvent.self)
        }
        Rules { }
    }
    let transport = MembershipRecordingTransport()
    let keeper = LandKeeper<MembershipTestState>(definition: definition, initialState: MembershipTestState())
    let encodingConfig = TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
    let adapter = TransportAdapter<MembershipTestState>(
        keeper: keeper,
        transport: transport,
        landID: "membership-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    let player = PlayerID("p1")

    await adapter.onConnect(sessionID: session1, clientID: client1)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: session1,
        clientID: client1,
        playerID: player
    )
    await transport.clear()

    await adapter.sendEvent(AnyServerEvent(MembershipMessageEvent(message: "old")), to: .player(player))
    await adapter.onDisconnect(sessionID: session1, clientID: client1)

    let session2 = SessionID("sess-2")
    let client2 = ClientID("cli-2")
    await adapter.onConnect(sessionID: session2, clientID: client2)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: session2,
        clientID: client2,
        playerID: player
    )

    await adapter.syncNow()

    let messages = await transport.recordedMessages()
    var opcode103Count = 0
    for data in messages {
        let unpacked = try unpack(data)
        guard case .array(let array) = unpacked,
              case .int(let opcode) = array.first else { continue }
        if opcode == 103 { opcode103Count += 1 }
    }

    #expect(opcode103Count == 0, "Stale targeted event should not be delivered after rejoin")
}
