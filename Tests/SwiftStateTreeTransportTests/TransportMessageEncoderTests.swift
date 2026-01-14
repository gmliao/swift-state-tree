import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

struct TransportMessageEncoderTests {
    
    @Test("OpcodeTransportMessageEncoder encodes known event to opcode")
    func testEncodeKnownEvent() throws {
        // Setup
        let eventHashes = ["PlayerShoot": 1]
        let encoder = OpcodeTransportMessageEncoder(
            eventHashes: eventHashes,
            clientEventHashes: nil
        )
        
        let event = AnyServerEvent(
            type: "PlayerShoot",
            payload: AnyCodable("bang"),
            rawBody: nil
        )
        
        let message = TransportMessage.event(event: .fromServer(event: event))
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(103), Direction(1), EventOpcode(1), Payload]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 4)
        #expect(jsonArray?[0] as? Int == 103) // TransportOpcode.event
        #expect(jsonArray?[1] as? Int == 1)   // Direction.fromServer
        #expect(jsonArray?[2] as? Int == 1)   // Event Opcode for "PlayerShoot"
        #expect(jsonArray?[3] as? String == "bang")
    }
    
    @Test("OpcodeTransportMessageEncoder encodes unknown event to string")
    func testEncodeUnknownEvent() throws {
        // Setup
        let eventHashes = ["PlayerShoot": 1]
        let encoder = OpcodeTransportMessageEncoder(
            eventHashes: eventHashes,
            clientEventHashes: nil
        )
        
        let event = AnyServerEvent(
            type: "UnknownEvent",
            payload: AnyCodable("test"),
            rawBody: nil
        )
        
        let message = TransportMessage.event(event: .fromServer(event: event))
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(103), Direction(1), EventString("UnknownEvent"), Payload]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 4)
        #expect(jsonArray?[0] as? Int == 103)
        #expect(jsonArray?[1] as? Int == 1)
        #expect(jsonArray?[2] as? String == "UnknownEvent") // Fallback to string
        #expect(jsonArray?[3] as? String == "test")
    }
    
    @Test("OpcodeTransportMessageEncoder encodes client event with hashes")
    func testEncodeClientEvent() throws {
        // Setup
        let clientEventHashes = ["MoveTo": 42]
        let encoder = OpcodeTransportMessageEncoder(
            eventHashes: nil,
            clientEventHashes: clientEventHashes
        )
        
        let event = AnyClientEvent(
            type: "MoveTo",
            payload: AnyCodable("loc"),
            rawBody: nil
        )
        
        // Note: TransportMessage.event(event:) usually comes from client, 
        // but verify encoder handles it if we ever need to re-encode or reflect it.
        let message = TransportMessage.event(event: .fromClient(event: event))
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(103), Direction(0), EventOpcode(42), Payload]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 4)
        #expect(jsonArray?[0] as? Int == 103)
        #expect(jsonArray?[1] as? Int == 0)   // Direction.fromClient
        #expect(jsonArray?[2] as? Int == 42)  // Event Opcode for "MoveTo"
        #expect(jsonArray?[3] as? String == "loc")
    }
    @Test("OpcodeTransportMessageEncoder encodes payload as array when compression enabled")
    func testEncodePayloadAsArray() throws {
        // Setup
        let eventHashes = ["Test": 1]
        let encoder = OpcodeTransportMessageEncoder(
            eventHashes: eventHashes,
            enablePayloadCompression: true
        )
        
        struct TestPayload: Encodable {
            let x: Int
            let y: Int
            let name: String
        }
        
        let payload = TestPayload(x: 10, y: 20, name: "foo")
        
        let event = AnyServerEvent(
            type: "Test",
            payload: AnyCodable(payload),
            rawBody: nil
        )
        
        let message = TransportMessage.event(event: .fromServer(event: event))
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(103), Direction(1), EventOpcode(1), POSTIONAL_ARRAY]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 4)
        
        // Check payload is array [10, 20, "foo"]
        // Note: Reflection order is usually declaration order in Swift, but not guaranteed across all ABI versions.
        // For standard structs it's usually reliable.
        if let payloadArray = jsonArray?[3] as? [Any] {
            #expect(payloadArray.count == 3)
            #expect(payloadArray[0] as? Int == 10)
            #expect(payloadArray[1] as? Int == 20)
            #expect(payloadArray[2] as? String == "foo")
        } else {
            Issue.record("Payload should be an array")
        }
    }
}
