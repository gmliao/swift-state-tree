// Tests/SwiftStateTreeTransportTests/TransportAdapterOpcodeDecodingTests.swift
//
// Tests for TransportAdapter decoding opcode array format messages from client

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

struct TestAction: ActionPayload {
    typealias Response = TestActionResponse
    
    let message: String
}

struct TestActionResponse: ResponsePayload {
    let success: Bool
}

struct TestIncrementEvent: ClientEventPayload {
    // Empty payload
}

@StateNodeBuilder
struct OpcodeDecodingTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var lastAction: String? = nil
}

@Suite("TransportAdapter Opcode Decoding Tests")
struct TransportAdapterOpcodeDecodingTests {
    
    @Test("TransportAdapter decodes opcode array format action from client")
    func testDecodeOpcodeArrayAction() async throws {
        let definition = Land(
            "opcode-test",
            using: OpcodeDecodingTestState.self
        ) {
            Rules {
                HandleAction(TestAction.self) { (state: inout OpcodeDecodingTestState, action: TestAction, _: LandContext) in
                    state.lastAction = action.message
                }
            }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<OpcodeDecodingTestState>(
            definition: definition,
            initialState: OpcodeDecodingTestState()
        )
        let adapter = TransportAdapter<OpcodeDecodingTestState>(
            keeper: keeper,
            transport: transport,
            landID: "opcode-test"
        )
        await transport.setDelegate(adapter)
        
        let sessionID = SessionID("sess-1")
        let clientID = ClientID("cli-1")
        let playerID = PlayerID("player-1")
        
        // Connect and join
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: sessionID, clientID: clientID, playerID: playerID)
        
        // Create opcode array format action message
        // [101, requestID, typeIdentifier, payload(base64)]
        let actionPayload = TestAction(message: "Hello from opcode array")
        let payloadJson = try JSONEncoder().encode(actionPayload)
        let payloadBase64 = payloadJson.base64EncodedString()
        
        let actionArray: [Any] = [
            101, // opcode
            "action-req-opcode-001",
            "TestAction",
            payloadBase64
        ]
        
        let actionData = try JSONSerialization.data(withJSONObject: actionArray)
        
        // Send opcode array format message
        await adapter.onMessage(actionData, from: sessionID)
        
        // Wait a bit for processing
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Verify action was processed
        let state = await keeper.currentState()
        #expect(state.lastAction == "Hello from opcode array", "Action should be processed from opcode array format")
    }
    
    @Test("TransportAdapter decodes opcode array format event from client")
    func testDecodeOpcodeArrayEvent() async throws {
        let definition = Land(
            "opcode-event-test",
            using: OpcodeDecodingTestState.self
        ) {
            Rules {
                OnClientEvent(TestIncrementEvent.self) { (state: inout OpcodeDecodingTestState, _: TestIncrementEvent, _: LandContext) in
                    state.ticks += 1
                }
            }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<OpcodeDecodingTestState>(
            definition: definition,
            initialState: OpcodeDecodingTestState()
        )
        let adapter = TransportAdapter<OpcodeDecodingTestState>(
            keeper: keeper,
            transport: transport,
            landID: "opcode-event-test"
        )
        await transport.setDelegate(adapter)
        
        let sessionID = SessionID("sess-1")
        let clientID = ClientID("cli-1")
        let playerID = PlayerID("player-1")
        
        // Connect and join
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: sessionID, clientID: clientID, playerID: playerID)
        
        // Create opcode array format event message
        // [103, direction(0=client), type, payload, rawBody?]
        let eventArray: [Any] = [
            103, // opcode
            0, // direction: fromClient
            "TestIncrementEvent",
            [:] // empty payload
        ]
        
        let eventData = try JSONSerialization.data(withJSONObject: eventArray)
        
        // Send opcode array format message
        await adapter.onMessage(eventData, from: sessionID)
        
        // Wait a bit for processing
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Verify event was processed
        let state = await keeper.currentState()
        #expect(state.ticks == 1, "Event should be processed from opcode array format")
    }
    
    @Test("TransportAdapter handles mixed JSON and opcode array formats")
    func testMixedFormatDecoding() async throws {
        let definition = Land(
            "mixed-format-test",
            using: OpcodeDecodingTestState.self
        ) {
            Rules {
                HandleAction(TestAction.self) { (state: inout OpcodeDecodingTestState, action: TestAction, _: LandContext) in
                    state.lastAction = action.message
                }
            }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<OpcodeDecodingTestState>(
            definition: definition,
            initialState: OpcodeDecodingTestState()
        )
        let adapter = TransportAdapter<OpcodeDecodingTestState>(
            keeper: keeper,
            transport: transport,
            landID: "mixed-format-test"
        )
        await transport.setDelegate(adapter)
        
        let sessionID = SessionID("sess-1")
        let clientID = ClientID("cli-1")
        let playerID = PlayerID("player-1")
        
        // Connect and join
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: sessionID, clientID: clientID, playerID: playerID)
        
        // Test 1: Send JSON format action
        let jsonActionPayload = TestAction(message: "JSON format")
        let jsonAction = TransportMessage.action(
            requestID: "json-action-001",
            action: ActionEnvelope(
                typeIdentifier: "TestAction",
                payload: AnyCodable(jsonActionPayload)
            )
        )
        let jsonData = try JSONEncoder().encode(jsonAction)
        await adapter.onMessage(jsonData, from: sessionID)
        
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        
        var state = await keeper.currentState()
        #expect(state.lastAction == "JSON format", "JSON format action should be processed")
        
        // Test 2: Send opcode array format action
        let opcodeActionPayload = TestAction(message: "Opcode array format")
        let payloadJson = try JSONEncoder().encode(opcodeActionPayload)
        let payloadBase64 = payloadJson.base64EncodedString()
        
        let opcodeArray: [Any] = [
            101, // opcode
            "opcode-action-001",
            "TestAction",
            payloadBase64
        ]
        
        let opcodeData = try JSONSerialization.data(withJSONObject: opcodeArray)
        await adapter.onMessage(opcodeData, from: sessionID)
        
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        
        state = await keeper.currentState()
        #expect(state.lastAction == "Opcode array format", "Opcode array format action should be processed")
    }
}
