// Tests/SwiftStateTreeTests/ActionEventSyncTests.swift
//
// Tests to verify that actions and events modify state correctly.
// Note: syncNow() is NOT called automatically after handler completion.
// Sync must be triggered via tick mechanism (if configured) or manual sync calls.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
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

// MARK: - Test Helpers

extension LandKeeper {
    /// Helper method to send an action using handleActionEnvelope
    func sendAction<A: ActionPayload>(
        _ action: A,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> AnyCodable {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: A.self),
            payload: AnyCodable(action)
        )
        return try await handleActionEnvelope(
            envelope,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID
        )
    }
}

// MARK: - Mock Transport for Testing

/// A transport that records what each of its keeper's turns hands over (#546 L2d: a live
/// keeper's transport runs its sync phase in turn).
final class MockLandKeeperTransport: LandKeeperTransport, @unchecked Sendable {
    typealias CoreEventTarget = SwiftStateTree.EventTarget

    private let lock = NSLock()
    private var events = 0
    private var phases = 0
    private var last: InTurnServerEvent?
    private var observed: [Int] = []

    /// Events handed over, over all turns.
    var sendEventCallCount: Int { lock.withLock { events } }
    /// Sync phases run (a turn with `includeSync`).
    var syncPhaseCount: Int { lock.withLock { phases } }
    var lastEvent: AnyServerEvent? { lock.withLock { last?.event } }
    var lastTarget: CoreEventTarget? { lock.withLock { last?.target } }
    /// `count` as each sync phase saw it, in turn order.
    var syncObservedCounts: [Int] { lock.withLock { observed } }
    /// "sync count `n`" for each sync phase, as it runs: a test waits on the sync it needs
    /// instead of polling `syncObservedCounts` against a deadline (#458). Not cleared by `reset`.
    let syncLog = EventLog()

    func sendEventToTransport(_ event: AnyServerEvent, to target: CoreEventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}

    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events turnEvents: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        let seen: Int? = lock.withLock {
            events += turnEvents.count
            if let final = turnEvents.last { last = final }
            guard includeSync else { return nil }
            phases += 1
            guard let synced = state as? ActionEventSyncTestState else { return nil }
            observed.append(synced.count)
            return synced.count
        }
        if let seen { syncLog.append("sync count \(seen)") }
        return InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }

    func reset() {
        lock.withLock {
            events = 0
            phases = 0
            last = nil
            observed = []
        }
    }
    func waitForWriterDrainForInTurnSync() async {}
}

// MARK: - Tests

@Test("Action execution modifies state")
func testActionModifiesState() async throws {
    // Arrange
    let definition = Land(
        "action-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            OnJoin { state, ctx in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleAction(IncrementAction.self) { state, action, ctx in
                state.count += action.amount
                // Note: syncNow() is NOT called automatically after handler completes
                // Sync happens via tick mechanism (if configured) or manual sync calls
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
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Clear sync call counts
    mockTransport.reset()
    
    // Act: Execute action
    let action = IncrementAction(amount: 5)
    let response = try await keeper.sendAction(
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
    
    // Note: syncNow() is NOT called automatically after action/event handlers complete
    // Sync must be triggered manually (via ctx.syncNow() in spawn) or via tick mechanism
    // This test verifies state modification, not automatic sync
}

@Test("Event execution modifies state")
func testEventModifiesState() async throws {
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
            OnJoin { state, ctx in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleEvent(IncrementEvent.self) { state, event, ctx in
                state.count += event.amount
                // Note: syncNow() is NOT called automatically after handler completes
                // Sync happens via tick mechanism (if configured) or manual sync calls
            }
            
            HandleEvent(SetMessageEvent.self) { state, event, ctx in
                state.message = event.message
                // Note: syncNow() is NOT called automatically after handler completes
                // Sync happens via tick mechanism (if configured) or manual sync calls
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
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Clear sync call counts
    mockTransport.reset()
    
    // Act: Send increment event
    let incrementEvent = AnyClientEvent(IncrementEvent(amount: 3))
    try await keeper.handleClientEvent(incrementEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait a bit for sync to be called
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Verify state was modified
    var state = await keeper.currentState()
    #expect(state.count == 3, "State count should be 3 after event")
    
    // Note: syncNow() is NOT called automatically after action/event handlers complete
    // Sync must be triggered manually (via ctx.syncNow() in spawn) or via tick mechanism
    
    // Clear and test another event
    mockTransport.reset()
    
    // Act: Send set message event
    let setMessageEvent = AnyClientEvent(SetMessageEvent(message: "Hello World"))
    try await keeper.handleClientEvent(setMessageEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait a bit for sync to be called
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Verify state was modified
    state = await keeper.currentState()
    #expect(state.message == "Hello World", "State message should be updated")
    
    // Note: syncNow() is NOT called automatically after action/event handlers complete
    // Sync must be triggered manually (via ctx.syncNow() in spawn) or via tick mechanism
}

@Test("Multiple actions and events modify state correctly")
func testMultipleActionsAndEventsModifyState() async throws {
    // Arrange
    let definition = Land(
        "multi-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        ClientEvents {
            Register(IncrementEvent.self)
        }
        
        Rules {
            OnJoin { state, ctx in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleAction(IncrementAction.self) { state, action, ctx in
                state.count += action.amount
                // Note: syncNow() is NOT called automatically after handler completes
                // Sync happens via tick mechanism (if configured) or manual sync calls
                return IncrementResponse(success: true, newCount: state.count)
            }
            
            HandleEvent(IncrementEvent.self) { state, event, ctx in
                state.count += event.amount
                // Note: syncNow() is NOT called automatically after handler completes
                // Sync happens via tick mechanism (if configured) or manual sync calls
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
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Clear sync call counts
    mockTransport.reset()
    
    // Act: Execute action
    let action = IncrementAction(amount: 2)
    _ = try await keeper.sendAction(action, playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(50))
    
    // Act: Send event
    let event = AnyClientEvent(IncrementEvent(amount: 3))
    try await keeper.handleClientEvent(event, playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(50))
    
    // Act: Execute another action
    let action2 = IncrementAction(amount: 1)
    _ = try await keeper.sendAction(action2, playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Verify final state
    let state = await keeper.currentState()
    #expect(state.count == 6, "State count should be 6 (2 + 3 + 1)")
    
    // Note: syncNow() is NOT called automatically after action/event handlers complete
    // Sync must be triggered manually (via ctx.syncNow() in spawn) or via tick mechanism
    // This test verifies state modification, not automatic sync
}

// MARK: - Sync Mechanism Tests

@Test("Action execution with tick mechanism triggers sync")
func testActionWithTickTriggersSync() async throws {
    // Arrange: Configure Land with tick mechanism
    let definition = Land(
        "action-tick-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            OnJoin { state, ctx in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleAction(IncrementAction.self) { state, action, ctx in
                state.count += action.amount
                return IncrementResponse(success: true, newCount: state.count)
            }
        }
        
        Lifetime {
            Tick(every: .milliseconds(20)) { state, _ in
                // Tick handler for game logic
            }
            StateSync(every: .milliseconds(20)) { _, _ in
                // Read-only sync callback
            }
        }
    }
    
    let mockTransport = MockLandKeeperTransport()
    // No loop phase offset: the tick and sync loops start one interval after creation.
    let keeper = LandKeeper<ActionEventSyncTestState>(
        definition: definition,
        initialState: ActionEventSyncTestState(),
        enableLoopPhaseOffset: false
    )
    
    await keeper.setTransport(mockTransport)
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // Join player
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait for OnInitialize and sync loop to start (sync interval is auto-configured to 20ms)
    try await Task.sleep(for: .milliseconds(100))
    
    // Clear sync call counts
    mockTransport.reset()
    
    // Act: Execute action
    let action = IncrementAction(amount: 5)
    _ = try await keeper.sendAction(action, playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait for a sync phase that sees the action's change: a sync before the tick applied it
    // would see the old count and does not count. Woken by the sync itself, not a deadline.
    #expect(await mockTransport.syncLog.waitFor("sync count 5"), "no sync saw the action's change")
    
    // Assert: Verify state was modified
    let state = await keeper.currentState()
    #expect(state.count == 5, "State count should be 5 after action")
    
    // Assert: Verify sync was called by sync mechanism
    let observed = mockTransport.syncObservedCounts
    #expect(observed.contains(5), "a sync after the action should see count == 5; syncs saw \(observed)")
}

@Test("Event execution with tick mechanism triggers sync")
func testEventWithTickTriggersSync() async throws {
    // Arrange: Configure Land with tick mechanism
    let definition = Land(
        "event-tick-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        ClientEvents {
            Register(IncrementEvent.self)
        }
        
        Rules {
            OnJoin { state, ctx in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleEvent(IncrementEvent.self) { state, event, ctx in
                state.count += event.amount
            }
        }
        
        Lifetime {
            Tick(every: .milliseconds(20)) { state, _ in
                // Tick handler for game logic
            }
            StateSync(every: .milliseconds(20)) { _, _ in
                // Read-only sync callback
            }
        }
    }
    
    let mockTransport = MockLandKeeperTransport()
    // No loop phase offset: the tick and sync loops start one interval after creation.
    let keeper = LandKeeper<ActionEventSyncTestState>(
        definition: definition,
        initialState: ActionEventSyncTestState(),
        enableLoopPhaseOffset: false
    )
    
    await keeper.setTransport(mockTransport)
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // Join player
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait for OnInitialize and sync loop to start (sync interval is auto-configured to 20ms)
    try await Task.sleep(for: .milliseconds(100))
    
    // Clear sync call counts
    mockTransport.reset()
    
    // Act: Send event
    let event = AnyClientEvent(IncrementEvent(amount: 3))
    try await keeper.handleClientEvent(event, playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait for a sync phase that sees the event's change: a sync before the tick applied it
    // would see the old count and does not count. Woken by the sync itself, not a deadline.
    #expect(await mockTransport.syncLog.waitFor("sync count 3"), "no sync saw the event's change")
    
    // Assert: Verify state was modified
    let state = await keeper.currentState()
    #expect(state.count == 3, "State count should be 3 after event")
    
    // Assert: Verify sync was called by sync mechanism
    let observed = mockTransport.syncObservedCounts
    #expect(observed.contains(3), "a sync after the event should see count == 3; syncs saw \(observed)")
}

@Test("Manual syncNow() in spawn triggers sync")
func testManualSyncNowRequest() async throws {
    // Arrange
    let definition = Land(
        "manual-sync-test",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            OnJoin { state, ctx in
                state.players[ctx.playerID] = "Joined"
            }
            
            HandleAction(IncrementAction.self) { state, action, ctx in
                state.count += action.amount
                
                // Request sync deterministically (flushed at end of tick)
                ctx.requestSyncNow()
                
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
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Clear sync call counts
    mockTransport.reset()
    
    // Act: Execute action
    let action = IncrementAction(amount: 7)
    _ = try await keeper.sendAction(action, playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Assert: Verify state was modified
    let state = await keeper.currentState()
    #expect(state.count == 7, "State count should be 7 after action")
    
    // Assert: Verify sync was called manually
    let syncNowCount = mockTransport.syncPhaseCount
    #expect(syncNowCount > 0, "Sync should be called when ctx.requestSyncNow() is invoked")
}

/// Payload fixtures of `testHandleActionEnvelopeDecodesPayloadTypes`, at file scope: an extension macro can't attach to a local type.
fileprivate enum TestHandleActionEnvelopeDecodesPayloadTypesFixtures {
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
}

@Test("handleActionEnvelope correctly decodes action payload with different types")
func testHandleActionEnvelopeDecodesPayloadTypes() async throws {
    let definition = Land(
        "test-action-decode",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            HandleAction(TestHandleActionEnvelopeDecodesPayloadTypesFixtures.TestActionWithTypes.self) { state, action, ctx in
                state.count = action.intValue
                state.message = action.stringValue
                return TestHandleActionEnvelopeDecodesPayloadTypesFixtures.TestActionResponse(success: action.boolValue)
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
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Act: Create action envelope with properly typed JSON payload
    let action = TestHandleActionEnvelopeDecodesPayloadTypesFixtures.TestActionWithTypes(
        intValue: 42,
        stringValue: "test",
        boolValue: true,
        doubleValue: 3.14
    )
    
    let envelope = ActionEnvelope(
        typeIdentifier: "TestActionWithTypes",
        payload: AnyCodable(action)
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
    let actionResponse = response.base as? TestHandleActionEnvelopeDecodesPayloadTypesFixtures.TestActionResponse
    #expect(actionResponse?.success == true, "Bool value should be decoded correctly")
}

/// Payload fixtures of `testHandleActionEnvelopeTypeMismatch`, at file scope: an extension macro can't attach to a local type.
fileprivate enum TestHandleActionEnvelopeTypeMismatchFixtures {
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
}

@Test("handleActionEnvelope throws error when payload type mismatches")
func testHandleActionEnvelopeTypeMismatch() async throws {
    let definition = Land(
        "test-type-mismatch",
        using: ActionEventSyncTestState.self
    ) {
        Rules {
            HandleAction(TestHandleActionEnvelopeTypeMismatchFixtures.IntAction.self) { state, action, ctx in
                return TestHandleActionEnvelopeTypeMismatchFixtures.TestActionResponse(success: true)
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
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Act: Create action envelope with wrong type (string instead of int)
    let wrongPayload = ["value": "not-an-int"]  // Should be Int, not String
    
    let envelope = ActionEnvelope(
        typeIdentifier: "IntAction",
        payload: AnyCodable(wrongPayload)
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
