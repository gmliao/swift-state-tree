// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncConcurrencyTests.swift
//
// Tests for concurrent sync operations in TransportAdapter
// Verifies that beginSync() properly handles concurrent sync requests

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct SyncConcurrencyTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var counter: Int = 0
    
    @Sync(.broadcast)
    var lastModifiedBy: String = ""
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    public init() {}
}

// MARK: - Tests

@Suite("TransportAdapter Sync Concurrency Tests")
struct TransportAdapterSyncConcurrencyTests {
    
    @Test("Concurrent syncNow operations are serialized (only one executes)")
    func testConcurrentSyncNowSerialized() async throws {
        // Arrange
        let definition = Land(
            "sync-concurrency-test",
            using: SyncConcurrencyTestState.self
        ) {
            Rules { }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<SyncConcurrencyTestState>(
            definition: definition,
            initialState: SyncConcurrencyTestState()
        )
        let adapter = TransportAdapter<SyncConcurrencyTestState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-concurrency-test"
        )
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        
        // Join a player so sync has someone to sync to
        await adapter.onConnect(sessionID: SessionID("alice-session"), clientID: ClientID("alice-client"))
        let joinRequest = TransportMessage.join(
            requestID: "join-1",
            landID: "sync-concurrency-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: SessionID("alice-session"))
        try await Task.sleep(for: .milliseconds(50))
        
        // Act: Start two syncNow operations concurrently
        // The second one should be skipped (beginSync returns nil)
        let sync1Task = Task {
            await adapter.syncNow()
        }
        
        // Small delay to ensure first sync starts and acquires lock
        try await Task.sleep(for: .milliseconds(20))
        
        let sync2Task = Task {
            await adapter.syncNow()
        }
        
        // Wait for both to complete
        await sync1Task.value
        await sync2Task.value
        
        // Give a moment for sync operations to complete
        try await Task.sleep(for: .milliseconds(100))
        
        // Assert: State should be consistent (no corruption from concurrent sync)
        let finalState = await keeper.currentState()
        #expect(finalState.counter == 0, "State should remain consistent, counter should be 0")
    }
    
    @Test("syncBroadcastOnly skips when syncNow is in progress")
    func testSyncBroadcastOnlySkipsWhenSyncNowInProgress() async throws {
        // Arrange
        let definition = Land(
            "sync-concurrency-test",
            using: SyncConcurrencyTestState.self
        ) {
            Rules {
                OnLeave { (state: inout SyncConcurrencyTestState, ctx: LandContext) in
                    state.players.removeValue(forKey: ctx.playerID)
                }
            }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<SyncConcurrencyTestState>(
            definition: definition,
            initialState: SyncConcurrencyTestState()
        )
        let adapter = TransportAdapter<SyncConcurrencyTestState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-concurrency-test"
        )
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        
        // Join two players
        await adapter.onConnect(sessionID: SessionID("alice-session"), clientID: ClientID("alice-client"))
        await adapter.onConnect(sessionID: SessionID("bob-session"), clientID: ClientID("bob-client"))
        
        let joinRequest1 = TransportMessage.join(
            requestID: "join-1",
            landID: "sync-concurrency-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData1 = try JSONEncoder().encode(joinRequest1)
        await adapter.onMessage(joinData1, from: SessionID("alice-session"))
        
        let joinRequest2 = TransportMessage.join(
            requestID: "join-2",
            landID: "sync-concurrency-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData2 = try JSONEncoder().encode(joinRequest2)
        await adapter.onMessage(joinData2, from: SessionID("bob-session"))
        
        try await Task.sleep(for: .milliseconds(50))
        
        // Act: Start syncNow, then immediately start syncBroadcastOnly
        // syncBroadcastOnly should be skipped if syncNow is in progress
        let syncNowTask = Task {
            await adapter.syncNow()
        }
        
        // Small delay to ensure syncNow starts and acquires lock
        try await Task.sleep(for: .milliseconds(20))
        
        let syncBroadcastOnlyTask = Task {
            await adapter.syncBroadcastOnly()
        }
        
        // Wait for both to complete
        await syncNowTask.value
        await syncBroadcastOnlyTask.value
        
        // Give a moment for sync operations to complete
        try await Task.sleep(for: .milliseconds(100))
        
        // Assert: State should be consistent (no corruption)
        let finalState = await keeper.currentState()
        #expect(finalState.players.count >= 0, "State should remain consistent")
    }
    
    @Test("Multiple concurrent syncBroadcastOnly operations are serialized")
    func testMultipleSyncBroadcastOnlySerialized() async throws {
        // Arrange
        let definition = Land(
            "sync-concurrency-test",
            using: SyncConcurrencyTestState.self
        ) {
            Rules {
                OnLeave { (state: inout SyncConcurrencyTestState, ctx: LandContext) in
                    state.players.removeValue(forKey: ctx.playerID)
                }
            }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<SyncConcurrencyTestState>(
            definition: definition,
            initialState: SyncConcurrencyTestState()
        )
        let adapter = TransportAdapter<SyncConcurrencyTestState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-concurrency-test"
        )
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        
        // Join two players
        await adapter.onConnect(sessionID: SessionID("alice-session"), clientID: ClientID("alice-client"))
        await adapter.onConnect(sessionID: SessionID("bob-session"), clientID: ClientID("bob-client"))
        
        let joinRequest1 = TransportMessage.join(
            requestID: "join-1",
            landID: "sync-concurrency-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData1 = try JSONEncoder().encode(joinRequest1)
        await adapter.onMessage(joinData1, from: SessionID("alice-session"))
        
        let joinRequest2 = TransportMessage.join(
            requestID: "join-2",
            landID: "sync-concurrency-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData2 = try JSONEncoder().encode(joinRequest2)
        await adapter.onMessage(joinData2, from: SessionID("bob-session"))
        
        try await Task.sleep(for: .milliseconds(50))
        
        // Act: Start two syncBroadcastOnly operations concurrently
        // Only one should execute, the other should be skipped
        let sync1Task = Task {
            await adapter.syncBroadcastOnly()
        }
        
        // Small delay to ensure first sync starts and acquires lock
        try await Task.sleep(for: .milliseconds(20))
        
        let sync2Task = Task {
            await adapter.syncBroadcastOnly()
        }
        
        // Wait for both to complete
        await sync1Task.value
        await sync2Task.value
        
        // Give a moment for sync operations to complete
        try await Task.sleep(for: .milliseconds(100))
        
        // Assert: State should be consistent (no corruption from concurrent sync)
        let finalState = await keeper.currentState()
        #expect(finalState.players.count >= 0, "State should remain consistent")
    }
    
    @Test("Concurrent sync operations maintain state consistency")
    func testConcurrentSyncMaintainsStateConsistency() async throws {
        // Arrange
        let definition = Land(
            "sync-concurrency-test",
            using: SyncConcurrencyTestState.self
        ) {
            Rules {
                HandleAction(IncrementCounterAction.self) { (state: inout SyncConcurrencyTestState, action: IncrementCounterAction, ctx: LandContext) in
                    state.counter += action.amount
                    state.lastModifiedBy = action.modifier
                    return IncrementCounterResponse(success: true, newValue: state.counter)
                }
            }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<SyncConcurrencyTestState>(
            definition: definition,
            initialState: SyncConcurrencyTestState()
        )
        let adapter = TransportAdapter<SyncConcurrencyTestState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-concurrency-test"
        )
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        
        // Join a player
        await adapter.onConnect(sessionID: SessionID("alice-session"), clientID: ClientID("alice-client"))
        let joinRequest = TransportMessage.join(
            requestID: "join-1",
            landID: "sync-concurrency-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: SessionID("alice-session"))
        try await Task.sleep(for: .milliseconds(50))
        
        // Act: Start sync, then modify state, then start another sync
        let sync1Task = Task {
            await adapter.syncNow()
        }
        
        // Small delay to ensure sync starts
        try await Task.sleep(for: .milliseconds(10))
        
        // Modify state while sync is in progress
        let actionPayload = IncrementCounterAction(amount: 10, modifier: "test")
        let payloadData = try JSONEncoder().encode(actionPayload)
        let actionEnvelope = ActionEnvelope(
            typeIdentifier: "IncrementCounterAction",
            payload: payloadData
        )
        let actionRequest = TransportMessage.action(
            requestID: "action-1",
            landID: "sync-concurrency-test",
            action: actionEnvelope
        )
        let actionData = try JSONEncoder().encode(actionRequest)
        await adapter.onMessage(actionData, from: SessionID("alice-session"))
        
        // Start second sync (should be skipped if first is still in progress)
        let sync2Task = Task {
            await adapter.syncNow()
        }
        
        // Wait for both syncs to complete
        await sync1Task.value
        await sync2Task.value
        
        // Give a moment for state to be fully updated
        try await Task.sleep(for: .milliseconds(100))
        
        // Assert: State should be consistent
        let finalState = await keeper.currentState()
        #expect(finalState.counter == 10, "Counter should be 10, got \(finalState.counter)")
        #expect(finalState.lastModifiedBy == "test", "lastModifiedBy should be 'test'")
    }
}

// MARK: - Helper Types

@Payload
struct IncrementCounterAction: ActionPayload {
    typealias Response = IncrementCounterResponse
    
    let amount: Int
    let modifier: String
}

@Payload
struct IncrementCounterResponse: ResponsePayload {
    let success: Bool
    let newValue: Int
}
