// Tests/SwiftStateTreeTransportTests/TransportMessageDecoderTests.swift
//
// Tests for decoding opcode array format TransportMessage from client

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@Suite("TransportMessageDecoder Tests")
struct TransportMessageDecoderTests {
    
    @Test("OpcodeTransportMessageDecoder decodes joinResponse with encoding field")
    func testDecodeJoinResponseWithEncoding() throws {
        let decoder = OpcodeTransportMessageDecoder()
        
        // [105, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?]
        let array: [Any] = [
            105, // opcode
            "req-123",
            1, // success
            "demo-game",
            "instance-1",
            0, // playerSlot
            "opcodeJsonArray", // encoding
            NSNull() // reason
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        let message = try decoder.decode(from: jsonData)
        
        #expect(message.kind == .joinResponse)
        if case .joinResponse(let payload) = message.payload {
            #expect(payload.requestID == "req-123")
            #expect(payload.success == true)
            #expect(payload.landType == "demo-game")
            #expect(payload.landInstanceId == "instance-1")
            #expect(payload.playerSlot == 0)
            #expect(payload.encoding == "opcodeJsonArray")
        } else {
            Issue.record("Expected joinResponse payload")
        }
    }
    
    @Test("OpcodeTransportMessageDecoder decodes action from opcode array")
    func testDecodeAction() throws {
        let decoder = OpcodeTransportMessageDecoder()
        
        // [101, requestID, typeIdentifier, payload(base64)]
        let array: [Any] = [
            101, // opcode
            "action-req-456",
            "TestAction",
            "dGVzdC1wYXlsb2Fk" // base64 encoded "test-payload"
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        let message = try decoder.decode(from: jsonData)
        
        #expect(message.kind == .action)
        if case .action(let payload) = message.payload {
            #expect(payload.requestID == "action-req-456")
            #expect(payload.action.typeIdentifier == "TestAction")
            // Verify payload is base64 string
            if let payloadData = try? JSONEncoder().encode(payload.action.payload),
               let payloadString = String(data: payloadData, encoding: .utf8),
               payloadString.hasPrefix("\"") && payloadString.hasSuffix("\"") {
                let base64Value = String(payloadString.dropFirst().dropLast())
                #expect(base64Value == "dGVzdC1wYXlsb2Fk")
            } else {
                Issue.record("Expected base64 payload string")
            }
        } else {
            Issue.record("Expected action payload")
        }
    }
    
    @Test("OpcodeTransportMessageDecoder decodes event from opcode array")
    func testDecodeEvent() throws {
        let decoder = OpcodeTransportMessageDecoder()
        
        // [103, direction(0=client), type, payload, rawBody?]
        let array: [Any] = [
            103, // opcode
            0, // direction: fromClient
            "TestEvent",
            ["value": 42]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        let message = try decoder.decode(from: jsonData)
        
        #expect(message.kind == .event)
        if case .event(let event) = message.payload {
            if case .fromClient(let clientEvent) = event {
                #expect(clientEvent.type == "TestEvent")
                // Payload is AnyCodable, encode and decode to check value
                if let payloadData = try? JSONEncoder().encode(clientEvent.payload),
                   let payloadDict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                   let value = payloadDict["value"] as? Int {
                    #expect(value == 42)
                } else {
                    Issue.record("Expected payload with value=42")
                }
            } else {
                Issue.record("Expected fromClient event")
            }
        } else {
            Issue.record("Expected event payload")
        }
    }
    
    @Test("OpcodeTransportMessageDecoder decodes join from opcode array")
    func testDecodeJoin() throws {
        let decoder = OpcodeTransportMessageDecoder()
        
        // [104, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
        let array: [Any] = [
            104, // opcode
            "join-req-789",
            "demo-game",
            "instance-2",
            "player-1",
            "device-1",
            ["test": "value"]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        let message = try decoder.decode(from: jsonData)
        
        #expect(message.kind == .join)
        if case .join(let payload) = message.payload {
            #expect(payload.requestID == "join-req-789")
            #expect(payload.landType == "demo-game")
            #expect(payload.landInstanceId == "instance-2")
            #expect(payload.playerID == "player-1")
            #expect(payload.deviceID == "device-1")
            #expect(payload.metadata != nil)
        } else {
            Issue.record("Expected join payload")
        }
    }
    
    @Test("OpcodeTransportMessageDecoder handles invalid opcode")
    func testDecodeInvalidOpcode() throws {
        let decoder = OpcodeTransportMessageDecoder()
        
        let array: [Any] = [999, "invalid"] // Invalid opcode
        
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        
        #expect(throws: TransportMessageDecodingError.self) {
            try decoder.decode(from: jsonData)
        }
    }
    
    @Test("OpcodeTransportMessageDecoder handles too short array")
    func testDecodeTooShortArray() throws {
        let decoder = OpcodeTransportMessageDecoder()
        
        let array: [Any] = [105] // Only opcode, missing required fields
        
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        
        #expect(throws: TransportMessageDecodingError.self) {
            try decoder.decode(from: jsonData)
        }
    }
}
