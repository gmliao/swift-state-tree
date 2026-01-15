// Tests/SwiftStateTreeTransportTests/MessagePackJoinMessageTests.swift
//
// Specific tests for MessagePack Join message encoding/decoding
// This tests the exact format sent by the JS SDK client

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeMessagePack

@StateNodeBuilder
private struct MPJoinTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
}

@Test("Client SDK MessagePack Join message can be decoded by server")
func testClientSDKMessagePackJoinFormat() throws {
    // Simulate the exact bytes sent by the JS SDK client
    // This is the format from encodeMessageArrayToMessagePack in protocol.ts:
    // [104, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
    
    // Create a Join message as the JS SDK would encode it
    let requestID = "join-1768434969"
    let landType = "hero-defense"
    let playerID = "measure-player"
    
    // Build the MessagePack array manually to match JS SDK output
    let array: [MessagePackValue] = [
        .int(104),                           // opcode for join
        .string(requestID),                  // requestID
        .string(landType),                   // landType
        .nil,                                // landInstanceId (null)
        .string(playerID),                   // playerID
        .nil,                                // deviceID (null)
        .nil                                 // metadata (null)
    ]
    
    let packedData = try pack(.array(array))
    
    // Print hex bytes for debugging (first 16 bytes)
    let hexString = packedData.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("Packed MessagePack data (first 16 bytes): \(hexString)")
    
    // Now try to decode this with MessagePackTransportCodec like the server would
    let codec = MessagePackTransportCodec()
    
    do {
        let decoded = try codec.decode(TransportMessage.self, from: packedData)
        
        #expect(decoded.kind == .join)
        guard case .join(let joinPayload) = decoded.payload else {
            Issue.record("Expected join payload")
            return
        }
        #expect(joinPayload.requestID == requestID)
        #expect(joinPayload.landType == landType)
        #expect(joinPayload.playerID == playerID)
        
        print("✅ Successfully decoded client SDK MessagePack Join message")
    } catch {
        print("❌ Failed to decode: \(error)")
        Issue.record("Failed to decode client SDK Join message: \(error)")
        throw error
    }
}

@Test("Client SDK MessagePack Join message with UInt opcode can be decoded by server")
func testClientSDKMessagePackJoinFormatWithUIntOpcode() throws {
    // Some MessagePack implementations may encode small positive integers as unsigned.
    // Ensure the decoder accepts both int and uint opcodes.
    let requestID = "join-1768434969"
    let landType = "hero-defense"
    let playerID = "measure-player"

    let array: [MessagePackValue] = [
        .uint(104),                          // opcode for join (UInt)
        .string(requestID),
        .string(landType),
        .nil,
        .string(playerID),
        .nil,
        .nil
    ]

    let packedData = try pack(.array(array))
    let codec = MessagePackTransportCodec()

    let decoded = try codec.decode(TransportMessage.self, from: packedData)
    #expect(decoded.kind == .join)
    guard case .join(let joinPayload) = decoded.payload else {
        Issue.record("Expected join payload")
        return
    }
    #expect(joinPayload.requestID == requestID)
    #expect(joinPayload.landType == landType)
    #expect(joinPayload.playerID == playerID)
}

@Test("TransportAdapter can handle client SDK MessagePack Join")
func testTransportAdapterHandlesClientSDKJoin() async throws {
    let definition = Land("test-land", using: MPJoinTestState.self) {
        Rules { }
    }
    let keeper = LandKeeper<MPJoinTestState>(definition: definition, initialState: MPJoinTestState())
    let transport = WebSocketTransport()
    
    let encodingConfig = TransportEncodingConfig(
        message: .messagepack,
        stateUpdate: .opcodeJsonArray,
        enablePayloadCompression: true
    )
    
    let adapter = TransportAdapter<MPJoinTestState>(
        keeper: keeper,
        transport: transport,
        landID: "test-land",
        enableLegacyJoin: true,
        encodingConfig: encodingConfig
    )
    
    await transport.setDelegate(adapter)
    
    // Create a recording connection to capture responses
    let sessionID = SessionID("test-session")
    let connection = RecordingWebSocketConnection()
    await transport.handleConnection(sessionID: sessionID, connection: connection)
    
    // Build Join message exactly as JS SDK would
    let requestID = "join-test"
    let array: [MessagePackValue] = [
        .int(104),                      // join opcode
        .string(requestID),
        .string("test-land"),
        .nil,                           // landInstanceId
        .string("test-player"),
        .nil,                           // deviceID
        .nil                            // metadata
    ]
    
    let joinData = try pack(.array(array))
    
    // Send to adapter
    await transport.handleIncomingMessage(sessionID: sessionID, data: joinData)
    
    // Check that we got a response
    let messages = await connection.recordedMessages()
    #expect(messages.count >= 1, "Expected at least one response message")
    
    // Decode the response
    let responseData = messages[0]
    let unpacked = try unpack(responseData)
    
    guard case .array(let responseArray) = unpacked,
          responseArray.count >= 3,
          case .int(let opcode) = responseArray[0],
          opcode == 105 else {  // 105 = joinResponse
        Issue.record("Expected MessagePack joinResponse array with opcode 105")
        return
    }
    
    // Extract success field (index 2)
    guard case .int(let successInt) = responseArray[2] else {
        Issue.record("Expected success field at index 2")
        return
    }
    
    #expect(successInt == 1, "Join should succeed")
    print("✅ TransportAdapter successfully handled client SDK MessagePack Join")
}

// Helper actor for recording sent messages
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
