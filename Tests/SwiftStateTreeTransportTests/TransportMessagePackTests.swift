import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct MessagePackTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

private struct DummyActionPayload: Codable, Sendable, Equatable {
    let value: Int
}

private actor RecordingWebSocketConnection: WebSocketConnection {
    private(set) var sentMessages: [Data] = []

    func send(_ data: Data) async throws {
        sentMessages.append(data)
    }

    func close() async throws { }

    func recordedMessages() async -> [Data] {
        sentMessages
    }
}

@Test("MessagePack codec round-trips transport payloads")
func testMessagePackCodecRoundTrip() throws {
    let codec = MessagePackTransportCodec()
    let payload = DummyActionPayload(value: 7)
    let payloadData = try JSONEncoder().encode(payload)
    let envelope = ActionEnvelope(typeIdentifier: "DummyActionPayload", payload: payloadData)
    let message = TransportMessage.action(requestID: "req-1", landID: "demo", action: envelope)

    let encoded = try codec.encode(message)
    let decoded = try codec.decode(TransportMessage.self, from: encoded)

    #expect(decoded.kind == .action)
    guard case .action(let decodedPayload) = decoded.payload else {
        Issue.record("Expected action payload")
        return
    }
    #expect(decodedPayload.requestID == "req-1")
    #expect(decodedPayload.landID == "demo")
    #expect(decodedPayload.action.typeIdentifier == "DummyActionPayload")
    #expect(decodedPayload.action.payload == payloadData)

    let update = StateUpdate.diff([StatePatch(path: "/count", operation: .set(.int(5)))])
    let updateData = try codec.encode(update)
    let decodedUpdate = try codec.decode(StateUpdate.self, from: updateData)
    #expect(decodedUpdate == update)

    let snapshot = StateSnapshot(values: ["count": .int(5)])
    let snapshotData = try codec.encode(snapshot)
    let decodedSnapshot = try codec.decode(StateSnapshot.self, from: snapshotData)
    #expect(decodedSnapshot == snapshot)
}

@Test("TransportAdapter accepts MessagePack join and responds in MessagePack")
func testMessagePackTransportAdapterJoin() async throws {
    let definition = Land("mp-test", using: MessagePackTestState.self) {
        Rules { }
    }
    let keeper = LandKeeper<MessagePackTestState>(definition: definition, initialState: MessagePackTestState())
    let transport = WebSocketTransport()
    let codec = MessagePackTransportCodec()
    let adapter = TransportAdapter<MessagePackTestState>(
        keeper: keeper,
        transport: transport,
        landID: "mp-test",
        enableLegacyJoin: true,
        codec: codec
    )
    await transport.setDelegate(adapter)

    let sessionID = SessionID("session-1")
    let connection = RecordingWebSocketConnection()
    await transport.handleConnection(sessionID: sessionID, connection: connection)

    let joinMessage = TransportMessage.join(
        requestID: "join-1",
        landType: "mp-test",
        landInstanceId: nil,
        playerID: "player-1",
        deviceID: nil,
        metadata: nil
    )
    let joinData = try codec.encode(joinMessage)
    await transport.handleIncomingMessage(sessionID: sessionID, data: joinData)

    let messages = await connection.recordedMessages()
    #expect(messages.count >= 2)

    let joinResponse = try codec.decode(TransportMessage.self, from: messages[0])
    #expect(joinResponse.kind == .joinResponse)
    if case .joinResponse(let payload) = joinResponse.payload {
        #expect(payload.requestID == "join-1")
        #expect(payload.success == true)
        #expect(payload.playerID == "player-1")
    } else {
        Issue.record("Expected join response payload")
    }

    let snapshot = try codec.decode(StateSnapshot.self, from: messages[1])
    #expect(snapshot.values["count"] != nil)
}
