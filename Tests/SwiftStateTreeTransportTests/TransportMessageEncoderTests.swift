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
        
        @Payload
        struct TestPayload: ServerEventPayload {
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
        
        // Check payload is array encoded by @Payload macro.
        // Field order is deterministic ASCII sorting by property name.
        // For TestPayload { x, y, name } the order is: name, x, y.
        if let payloadArray = jsonArray?[3] as? [Any] {
            #expect(payloadArray.count == 3)
            #expect(payloadArray[0] as? String == "foo")
            #expect(payloadArray[1] as? Int == 10)
            #expect(payloadArray[2] as? Int == 20)
        } else {
            Issue.record("Payload should be an array")
        }
    }
    
    @Test("OpcodeTransportMessageEncoder encodes ActionResponse payload as array when compression enabled")
    func testEncodeActionResponsePayloadAsArray() throws {
        // Setup: Use a ResponsePayload with @Payload macro to ensure correct field order
        @Payload
        struct TestResponse: ResponsePayload {
            let success: Bool
            let newCount: Int
            let message: String
            
            init(success: Bool, newCount: Int, message: String) {
                self.success = success
                self.newCount = newCount
                self.message = message
            }
        }
        
        let response = TestResponse(success: true, newCount: 42, message: "done")
        let encoder = OpcodeTransportMessageEncoder(
            enablePayloadCompression: true
        )
        
        let message = TransportMessage.actionResponse(
            requestID: "req-123",
            response: AnyCodable(response)
        )
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(102), requestID, [success, newCount, message]]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 3)
        #expect(jsonArray?[0] as? Int == 102) // TransportOpcode.actionResponse
        #expect(jsonArray?[1] as? String == "req-123")
        
        // Verify payload is array with correct field order (from @Payload macro)
        if let payloadArray = jsonArray?[2] as? [Any] {
            #expect(payloadArray.count == 3)
            // Field order is deterministic ASCII sorting by property name:
            // message, newCount, success
            #expect(payloadArray[0] as? String == "done")
            #expect(payloadArray[1] as? Int == 42)
            #expect(payloadArray[2] as? Bool == true)
        } else {
            Issue.record("ActionResponse payload should be an array")
        }
    }
    
    @Test("OpcodeTransportMessageEncoder encodes ActionResponse payload as object when compression disabled")
    func testEncodeActionResponsePayloadAsObject() throws {
        @Payload
        struct TestResponse: ResponsePayload {
            let success: Bool
            let newCount: Int
            
            init(success: Bool, newCount: Int) {
                self.success = success
                self.newCount = newCount
            }
        }
        
        let response = TestResponse(success: true, newCount: 42)
        let encoder = OpcodeTransportMessageEncoder(
            enablePayloadCompression: false
        )
        
        let message = TransportMessage.actionResponse(
            requestID: "req-456",
            response: AnyCodable(response)
        )
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(102), requestID, {success: true, newCount: 42}]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 3)
        #expect(jsonArray?[0] as? Int == 102)
        #expect(jsonArray?[1] as? String == "req-456")
        
        // Verify payload is object (not array)
        if let payloadObject = jsonArray?[2] as? [String: Any] {
            #expect(payloadObject["success"] as? Bool == true)
            #expect(payloadObject["newCount"] as? Int == 42)
        } else {
            Issue.record("ActionResponse payload should be an object when compression is disabled")
        }
    }
    
    @Test("OpcodeTransportMessageEncoder encodes Action payload as array when compression enabled")
    func testEncodeActionPayloadAsArray() throws {
        // Setup: Use an ActionPayload with @Payload macro to ensure correct field order
        @Payload
        struct TestAction: ActionPayload {
            typealias Response = TestActionResponse
            
            let amount: Int
            let target: String
            let enabled: Bool
            
            init(amount: Int, target: String, enabled: Bool) {
                self.amount = amount
                self.target = target
                self.enabled = enabled
            }
        }
        
        @Payload
        struct TestActionResponse: ResponsePayload {
            let success: Bool
        }
        
        let action = TestAction(amount: 100, target: "player1", enabled: true)
        let encoder = OpcodeTransportMessageEncoder(
            enablePayloadCompression: true
        )
        
        let envelope = ActionEnvelope(
            typeIdentifier: "TestAction",
            payload: AnyCodable(action)
        )
        let message = TransportMessage.action(
            requestID: "req-789",
            action: envelope
        )
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(101), requestID, typeIdentifier, [amount, target, enabled]]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 4)
        #expect(jsonArray?[0] as? Int == 101) // TransportOpcode.action
        #expect(jsonArray?[1] as? String == "req-789")
        #expect(jsonArray?[2] as? String == "TestAction")
        
        // Verify payload is array with correct field order (from @Payload macro)
        if let payloadArray = jsonArray?[3] as? [Any] {
            #expect(payloadArray.count == 3)
            // Field order is deterministic ASCII sorting by property name:
            // amount, enabled, target
            #expect(payloadArray[0] as? Int == 100)
            #expect(payloadArray[1] as? Bool == true)
            #expect(payloadArray[2] as? String == "player1")
        } else {
            Issue.record("Action payload should be an array")
        }
    }
    
    @Test("OpcodeTransportMessageEncoder encodes Action payload as object when compression disabled")
    func testEncodeActionPayloadAsObject() throws {
        @Payload
        struct TestAction: ActionPayload {
            typealias Response = TestActionResponse
            
            let amount: Int
            let target: String
            
            init(amount: Int, target: String) {
                self.amount = amount
                self.target = target
            }
        }
        
        @Payload
        struct TestActionResponse: ResponsePayload {
            let success: Bool
        }
        
        let action = TestAction(amount: 50, target: "player2")
        let encoder = OpcodeTransportMessageEncoder(
            enablePayloadCompression: false
        )
        
        let envelope = ActionEnvelope(
            typeIdentifier: "TestAction",
            payload: AnyCodable(action)
        )
        let message = TransportMessage.action(
            requestID: "req-999",
            action: envelope
        )
        
        // Execute
        let encodedData = try encoder.encode(message)
        let jsonArray = try JSONSerialization.jsonObject(with: encodedData) as? [Any]
        
        // Verify: [Opcode(101), requestID, typeIdentifier, {amount: 50, target: "player2"}]
        #expect(jsonArray != nil)
        #expect(jsonArray?.count == 4)
        #expect(jsonArray?[0] as? Int == 101)
        #expect(jsonArray?[1] as? String == "req-999")
        #expect(jsonArray?[2] as? String == "TestAction")
        
        // Verify payload is object (not array)
        if let payloadObject = jsonArray?[3] as? [String: Any] {
            #expect(payloadObject["amount"] as? Int == 50)
            #expect(payloadObject["target"] as? String == "player2")
        } else {
            Issue.record("Action payload should be an object when compression is disabled")
        }
    }
}
