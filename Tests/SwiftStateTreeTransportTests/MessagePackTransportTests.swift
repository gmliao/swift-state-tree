// Tests/SwiftStateTreeTransportTests/MessagePackTransportTests.swift
//
// Tests for MessagePack transport encoding/decoding

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeMessagePack

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
    let envelope = ActionEnvelope(typeIdentifier: "DummyActionPayload", payload: AnyCodable(payloadData))
    let message = TransportMessage.action(requestID: "req-1", action: envelope)

    let encoded = try codec.encode(message)
    let decoded = try codec.decode(TransportMessage.self, from: encoded)

    #expect(decoded.kind == .action)
    guard case .action(let decodedPayload) = decoded.payload else {
        Issue.record("Expected action payload")
        return
    }
    #expect(decodedPayload.requestID == "req-1")
    #expect(decodedPayload.action.typeIdentifier == "DummyActionPayload")
    
    let update = StateUpdate.diff([StatePatch(path: "/count", operation: .set(.int(5)))])
    let updateData = try codec.encode(update)
    let decodedUpdate = try codec.decode(StateUpdate.self, from: updateData)
    #expect(decodedUpdate == update)

    let snapshot = StateSnapshot(values: ["count": .int(5)])
    let snapshotData = try codec.encode(snapshot)
    let decodedSnapshot = try codec.decode(StateSnapshot.self, from: snapshotData)
    #expect(decodedSnapshot == snapshot)
}

@Test("MessagePack encoder uses same array structure as opcodeJsonArray")
func testMessagePackEncoderArrayStructure() throws {
    let opcodeEncoder = OpcodeTransportMessageEncoder()
    let msgpackEncoder = MessagePackTransportMessageEncoder()
    
    let payload = DummyActionPayload(value: 42)
    let payloadData = try JSONEncoder().encode(payload)
    let envelope = ActionEnvelope(typeIdentifier: "DummyActionPayload", payload: AnyCodable(payloadData))
    let message = TransportMessage.action(requestID: "req-1", action: envelope)
    
    // Encode with opcodeJsonArray (JSON)
    let jsonData = try opcodeEncoder.encode(message)
    let jsonArray = try JSONSerialization.jsonObject(with: jsonData) as? [Any]
    
    // Encode with MessagePack
    let msgpackData = try msgpackEncoder.encode(message)
    
    // Decode MessagePack back to array
    let msgpackArray = try unpack(msgpackData)
    guard case .array(let msgpackArrayValues) = msgpackArray else {
        Issue.record("Expected MessagePack array")
        return
    }
    
    // Convert MessagePack array to Swift array for comparison
    let msgpackSwiftArray = try msgpackArrayValues.map { value -> Any in
        try messagePackValueToAny(value)
    }
    
    // Both should have same structure (opcode, requestID, typeIdentifier, payload)
    #expect(jsonArray?.count == msgpackSwiftArray.count)
    
    // Compare opcode (first element)
    let jsonOpcode = jsonArray?[0] as? Int
    let msgpackOpcode: Int? = {
        let val = msgpackSwiftArray[0]
        if let intVal = val as? Int {
            return intVal
        } else if let int64Val = val as? Int64 {
            return Int(int64Val)
        }
        return nil
    }()
    #expect(jsonOpcode == msgpackOpcode)
    
    // Compare requestID (second element)
    let jsonRequestID = jsonArray?[1] as? String
    let msgpackRequestID = msgpackSwiftArray[1] as? String
    #expect(jsonRequestID == msgpackRequestID)
}

private func messagePackValueToAny(_ value: MessagePackValue) throws -> Any {
    switch value {
    case .nil: return NSNull()
    case .bool(let v): return v
    case .int(let v): return v
    case .uint(let v): return v
    case .float(let v): return v
    case .double(let v): return v
    case .string(let v): return v
    case .binary(let v): return v
    case .array(let arr): return try arr.map { try messagePackValueToAny($0) }
    case .map(let map): return try messagePackMapToDict(map)
    case .extended: throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extended type not supported"])
    }
}

private func messagePackMapToDict(_ map: [MessagePackValue: MessagePackValue]) throws -> [String: Any] {
    var dict: [String: Any] = [:]
    for (key, value) in map {
        guard case .string(let keyString) = key else {
            throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Non-string key"])
        }
        dict[keyString] = try messagePackValueToAny(value)
    }
    return dict
}

@Test("TransportAdapter accepts MessagePack join and responds in MessagePack")
func testMessagePackTransportAdapterJoin() async throws {
    let definition = Land("mp-test", using: MessagePackTestState.self) {
        Rules { }
    }
    let keeper = LandKeeper<MessagePackTestState>(definition: definition, initialState: MessagePackTestState())
    let transport = WebSocketTransport()
    // Use TransportEncodingConfig with messagepack encoding
    let encodingConfig = TransportEncodingConfig(
        message: .messagepack,
        stateUpdate: .jsonObject
    )
    let adapter = TransportAdapter<MessagePackTestState>(
        keeper: keeper,
        transport: transport,
        landID: "mp-test",
        enableLegacyJoin: true,
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)

    let sessionID = SessionID("session-1")
    let connection = RecordingWebSocketConnection()
    await transport.handleConnection(sessionID: sessionID, connection: connection)

    // For join messages from client, use opcode array format (same as opcodeJsonArray)
    // Encode join message as opcode array with MessagePack
    let encoder = MessagePackTransportMessageEncoder()
    let joinMessage = TransportMessage.join(
        requestID: "join-1",
        landType: "mp-test",
        landInstanceId: nil,
        playerID: "player-1",
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encoder.encode(joinMessage)
    await transport.handleIncomingMessage(sessionID: sessionID, data: joinData)

    let messages = await connection.recordedMessages()
    #expect(messages.count >= 1)

    // Decode join response (should be MessagePack opcode array format)
    let unpacked = try unpack(messages[0])
    guard case .array(let array) = unpacked, array.count >= 1,
          case .int(let opcode) = array[0],
          opcode == 105 else { // 105 = joinResponse opcode
        Issue.record("Expected MessagePack joinResponse array")
        return
    }
    
    // Convert to JSON array for OpcodeTransportMessageDecoder
    let jsonArray = try array.map { value -> Any in
        switch value {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        case .string(let v): return v
        case .bool(let v): return v ? 1 : 0
        case .nil: return NSNull()
        default: throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported value type"])
        }
    }
    let jsonData = try JSONSerialization.data(withJSONObject: jsonArray)
    let decoder = OpcodeTransportMessageDecoder()
    let joinResponse = try decoder.decode(from: jsonData)
    #expect(joinResponse.kind == MessageKind.joinResponse)
    if case .joinResponse(let payload) = joinResponse.payload {
        #expect(payload.requestID == "join-1")
    }
}
