// Tests/SwiftStateTreeTests/ActionEventSyncTests.swift
//
// Tests to verify that actions and events modify state and sync changes to clients

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// Import MockLandKeeperTransport from test module
// Note: MockLandKeeperTransport is in SwiftStateTreeTransportTests module
// We need to reference it directly or recreate it here

// MARK: - Test State

@StateNodeBuilder
struct ActionEventSyncTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    
    @Sync(.broadcast)
    var message: String = ""
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    public init() {}
}

// MARK: - Test Actions and Events

@Payload
struct IncrementAction: ActionPayload {
    typealias Response = IncrementResponse
    
    let amount: Int
}

@Payload
struct IncrementResponse: ResponsePayload {
    let success: Bool
    let newCount: Int
}

@Payload
struct SetMessageAction: ActionPayload {
    typealias Response = SetMessageResponse
    
    let message: String
}

@Payload
struct SetMessageResponse: ResponsePayload {
    let success: Bool
}

@Payload
struct IncrementEvent: ClientEventPayload {
    let amount: Int
}

@Payload
struct SetMessageEvent: ClientEventPayload {
    let message: String
}

// MARK: - Mock Transport for Testing

/// Mock implementation of LandKeeperTransport for testing sync calls
actor MockLandKeeperTransport: LandKeeperTransport {
    typealias CoreEventTarget = SwiftStateTree.EventTarget

    var sendEventCallCount = 0
    var syncNowCallCount = 0
    var syncBroadcastOnlyCallCount = 0
    var lastEvent: AnyServerEvent?
    var lastTarget: CoreEventTarget?
    
    func sendEventToTransport(_ event: AnyServerEvent, to target: CoreEventTarget) async {
        sendEventCallCount += 1
        lastEvent = event
        lastTarget = target
    }
    
    func syncNowFromTransport() async {
        syncNowCallCount += 1
    }
    
    func syncBroadcastOnlyFromTransport() async {
        syncBroadcastOnlyCallCount += 1
    }
    
    func reset() {
        sendEventCallCount = 0
        syncNowCallCount = 0
        syncBroadcastOnlyCallCount = 0
        lastEvent = nil
        lastTarget = nil
    }
}

// MARK: - Tests

@Test("Action execution modifies state and syncs changes")
func testActionModifiesStateAndSyncs() async throws {
    // Arrange
    let definition = Land(
        "action-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ActionEventSyncTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleAction(IncrementAction.self) { (state: inout ActionEventSyncTestState, action: IncrementAction, ctx: LandContext) in
                state.count += action.amount
                await ctx.syncNow()
                return IncrementResponse(success: true, newCount: state.count)
            }
        }
    }
    
    let mockTransport = MockLandKeeperTransport()
    let keeper = LandKeeper<ActionEventSyncTestState>(
        definition: definition,
        initialState: ActionEventSyncTestState()
    )
    
    await keeper.setTransport(mockTransport)
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // Join player
    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Clear sync call counts
    await mockTransport.reset()
    
    // Act: Execute action
    let action = IncrementAction(amount: 5)
    let response = try await keeper.handleAction(
        action,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID
    )
    
    // Wait a bit for sync to be called
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Verify state was modified
    let state = await keeper.currentState()
    #expect(state.count == 5, "State count should be 5 after action")
    
    // Assert: Verify response
    let actionResponse = response.base as? IncrementResponse
    #expect(actionResponse?.success == true, "Action should succeed")
    #expect(actionResponse?.newCount == 5, "Response should contain new count")
    
    let syncNowCount = await mockTransport.syncNowCallCount
    let syncBroadcastCount = await mockTransport.syncBroadcastOnlyCallCount
    #expect(syncNowCount > 0 || syncBroadcastCount > 0, "Sync should be called after action modifies state")
}

@Test("Event execution modifies state and syncs changes")
func testEventModifiesStateAndSyncs() async throws {
    // Arrange
    let definition = Land(
        "event-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        ClientEvents {
            Register(IncrementEvent.self)
            Register(SetMessageEvent.self)
        }
        
        Rules {
            OnJoin { (state: inout ActionEventSyncTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleEvent(IncrementEvent.self) { (state: inout ActionEventSyncTestState, event: IncrementEvent, ctx: LandContext) in
                state.count += event.amount
                await ctx.syncNow()
            }
            
            HandleEvent(SetMessageEvent.self) { (state: inout ActionEventSyncTestState, event: SetMessageEvent, ctx: LandContext) in
                state.message = event.message
                await ctx.syncNow()
            }
        }
    }
    
    let mockTransport = MockLandKeeperTransport()
    let keeper = LandKeeper<ActionEventSyncTestState>(
        definition: definition,
        initialState: ActionEventSyncTestState()
    )
    
    await keeper.setTransport(mockTransport)
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // Join player
    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Clear sync call counts
    await mockTransport.reset()
    
    // Act: Send increment event
    let incrementEvent = AnyClientEvent(IncrementEvent(amount: 3))
    await keeper.handleClientEvent(incrementEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait a bit for sync to be called
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Verify state was modified
    var state = await keeper.currentState()
    #expect(state.count == 3, "State count should be 3 after event")
    
    var syncNowCount = await mockTransport.syncNowCallCount
    var syncBroadcastCount = await mockTransport.syncBroadcastOnlyCallCount
    #expect(syncNowCount > 0 || syncBroadcastCount > 0, "Sync should be called after event modifies state")
    
    // Clear and test another event
    await mockTransport.reset()
    
    // Act: Send set message event
    let setMessageEvent = AnyClientEvent(SetMessageEvent(message: "Hello World"))
    await keeper.handleClientEvent(setMessageEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait a bit for sync to be called
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Verify state was modified
    state = await keeper.currentState()
    #expect(state.message == "Hello World", "State message should be updated")
    
    syncNowCount = await mockTransport.syncNowCallCount
    syncBroadcastCount = await mockTransport.syncBroadcastOnlyCallCount
    #expect(syncNowCount > 0 || syncBroadcastCount > 0, "Sync should be called after second event")
}

@Test("Multiple actions and events sync correctly")
func testMultipleActionsAndEventsSync() async throws {
    // Arrange
    let definition = Land(
        "multi-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        ClientEvents {
            Register(IncrementEvent.self)
        }
        
        Rules {
            OnJoin { (state: inout ActionEventSyncTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleAction(IncrementAction.self) { (state: inout ActionEventSyncTestState, action: IncrementAction, ctx: LandContext) in
                state.count += action.amount
                await ctx.syncNow()
                return IncrementResponse(success: true, newCount: state.count)
            }
            
            HandleEvent(IncrementEvent.self) { (state: inout ActionEventSyncTestState, event: IncrementEvent, ctx: LandContext) in
                state.count += event.amount
                await ctx.syncNow()
            }
        }
    }
    
    let mockTransport = MockLandKeeperTransport()
    let keeper = LandKeeper<ActionEventSyncTestState>(
        definition: definition,
        initialState: ActionEventSyncTestState()
    )
    
    await keeper.setTransport(mockTransport)
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // Join player
    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Clear sync call counts
    await mockTransport.reset()
    
    // Act: Execute action
    let action = IncrementAction(amount: 2)
    _ = try await keeper.handleAction(action, playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(50))
    
    // Act: Send event
    let event = AnyClientEvent(IncrementEvent(amount: 3))
    await keeper.handleClientEvent(event, playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(50))
    
    // Act: Execute another action
    let action2 = IncrementAction(amount: 1)
    _ = try await keeper.handleAction(action2, playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Verify final state
    let state = await keeper.currentState()
    #expect(state.count == 6, "State count should be 6 (2 + 3 + 1)")
    
    let syncNowCount = await mockTransport.syncNowCallCount
    let syncBroadcastCount = await mockTransport.syncBroadcastOnlyCallCount
    let totalSyncCalls = syncNowCount + syncBroadcastCount
    #expect(totalSyncCalls >= 2, "Sync should be called multiple times (at least 2)")
}

@Test("handleActionEnvelope correctly decodes action payload with different types")
func testHandleActionEnvelopeDecodesPayloadTypes() async throws {
    // Arrange
    @Payload
    struct TestActionWithTypes: ActionPayload {
        typealias Response = TestActionResponse
        
        let intValue: Int
        let stringValue: String
        let boolValue: Bool
        let doubleValue: Double
    }
    
    @Payload
    struct TestActionResponse: ResponsePayload {
        let success: Bool
    }
    
    let definition = Land(
        "test-action-decode",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            HandleAction(TestActionWithTypes.self) { (state: inout ActionEventSyncTestState, action: TestActionWithTypes, ctx: LandContext) in
                state.count = action.intValue
                state.message = action.stringValue
                return TestActionResponse(success: action.boolValue)
            }
        }
    }
    
    let keeper = LandKeeper<ActionEventSyncTestState>(
        definition: definition,
        initialState: ActionEventSyncTestState()
    )
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Act: Create action envelope with properly typed JSON payload
    let action = TestActionWithTypes(
        intValue: 42,
        stringValue: "test",
        boolValue: true,
        doubleValue: 3.14
    )
    
    let encoder = JSONEncoder()
    let payloadData = try encoder.encode(action)
    
    let envelope = ActionEnvelope(
        typeIdentifier: "TestActionWithTypes",
        payload: payloadData
    )
    
    // Act: Decode and handle action
    let response = try await keeper.handleActionEnvelope(
        envelope,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID
    )
    
    // Assert: Verify state was modified
    let state = await keeper.currentState()
    #expect(state.count == 42, "Int value should be decoded correctly")
    #expect(state.message == "test", "String value should be decoded correctly")
    
    // Assert: Verify response
    let actionResponse = response.base as? TestActionResponse
    #expect(actionResponse?.success == true, "Bool value should be decoded correctly")
}

@Test("handleActionEnvelope throws error when payload type mismatches")
func testHandleActionEnvelopeTypeMismatch() async throws {
    // Arrange
    @Payload
    struct IntAction: ActionPayload {
        typealias Response = TestActionResponse
        
        let value: Int
    }
    
    @Payload
    struct TestActionResponse: ResponsePayload {
        let success: Bool
    }
    
    let definition = Land(
        "test-type-mismatch",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            HandleAction(IntAction.self) { (state: inout ActionEventSyncTestState, action: IntAction, ctx: LandContext) in
                return TestActionResponse(success: true)
            }
        }
    }
    
    let keeper = LandKeeper<ActionEventSyncTestState>(
        definition: definition,
        initialState: ActionEventSyncTestState()
    )
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Act: Create action envelope with wrong type (string instead of int)
    let wrongPayload = ["value": "not-an-int"]  // Should be Int, not String
    let encoder = JSONEncoder()
    let payloadData = try encoder.encode(wrongPayload)
    
    let envelope = ActionEnvelope(
        typeIdentifier: "IntAction",
        payload: payloadData
    )
    
    // Assert: Should throw decoding error
    do {
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID
        )
        Issue.record("Should have thrown decoding error for type mismatch")
    } catch {
        // Expected: DecodingError for type mismatch
        #expect(error is DecodingError, "Should throw DecodingError for type mismatch")
    }
}
