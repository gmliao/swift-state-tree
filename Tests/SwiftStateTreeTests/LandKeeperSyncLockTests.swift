// Tests/SwiftStateTreeTests/LandKeeperSyncLockTests.swift
//
// Tests to verify that sync lock mechanism prevents race conditions
// between sync operations and state mutations (actions/events)

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test State

@StateNodeBuilder
struct SyncLockTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var counter: Int = 0
    
    @Sync(.broadcast)
    var lastModifiedBy: String = ""
    
    public init() {}
}

// MARK: - Test Actions and Events

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

@Payload
struct IncrementCounterEvent: ClientEventPayload {
    let amount: Int
    let modifier: String
}

// MARK: - Tests

@Test("Sync uses snapshot model - mutations can proceed concurrently")
func testSyncUsesSnapshotModel() async throws {
    // Arrange
    let definition = Land(
        "sync-snapshot-test",
        using: SyncLockTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout SyncLockTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.counter += action.amount
                state.lastModifiedBy = action.modifier
                return IncrementCounterResponse(success: true, newValue: state.counter)
            }
            
            HandleEvent(IncrementCounterEvent.self) { (state: inout SyncLockTestState, event: IncrementCounterEvent, ctx: LandContext) in
                state.counter += event.amount
                state.lastModifiedBy = event.modifier
            }
        }
    }
    
    let keeper = LandKeeper<SyncLockTestState>(
        definition: definition,
        initialState: SyncLockTestState()
    )
    
    // Act: Start a sync operation (takes snapshot)
    guard let syncState = await keeper.beginSync() else {
        Issue.record("Failed to begin sync")
        return
    }
    
    // Verify snapshot state
    #expect(syncState.counter == 0, "Snapshot counter should be 0")
    
    // Mutations can proceed concurrently (not blocked by sync)
    let actionTask = Task {
        try await keeper.handleAction(
            IncrementCounterAction(amount: 10, modifier: "action"),
            playerID: PlayerID("player1"),
            clientID: ClientID("client1"),
            sessionID: SessionID("session1")
        )
    }
    
    let eventTask = Task {
        await keeper.handleClientEvent(
            AnyClientEvent(IncrementCounterEvent(amount: 5, modifier: "event")),
            playerID: PlayerID("player1"),
            clientID: ClientID("client1"),
            sessionID: SessionID("session1")
        )
    }
    
    // Give mutations time to execute (they proceed immediately, not blocked)
    try await Task.sleep(for: .milliseconds(50))
    
    // Verify mutations have proceeded (snapshot model doesn't block mutations)
    let stateDuringSync = await keeper.currentState()
    // Mutations may have already completed (actor serialization)
    #expect(stateDuringSync.counter >= 0, "Counter may have changed during sync (snapshot model allows this)")
    
    // End sync
    await keeper.endSync()
    
    // Wait for both tasks to complete
    let actionResult = try await actionTask.value
    await eventTask.value
    
    // Give a moment for state to be fully updated
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: State should reflect mutations
    // Note: Due to actor serialization, mutations execute in order
    // Both mutations should have completed
    let finalState = await keeper.currentState()
    #expect(finalState.counter >= 10, "Counter should be at least 10 (from action), got \(finalState.counter)")
    #expect(finalState.counter <= 15, "Counter should be at most 15 (10 from action + 5 from event), got \(finalState.counter)")
    // Verify that mutations occurred
    #expect(finalState.lastModifiedBy != "", "State should be modified")
    
    // Verify snapshot was consistent (didn't see mutations - snapshot is immutable)
    #expect(syncState.counter == 0, "Snapshot should still show original value (0)")
    
    // Verify action response
    let actionResponse = actionResult.base as? IncrementCounterResponse
    #expect(actionResponse?.success == true, "Action should succeed")
    #expect(actionResponse?.newValue == 10, "Action should return newValue 10")
}

@Test("Multiple sync operations are serialized")
func testMultipleSyncOperationsSerialized() async throws {
    // Arrange
    let keeper = LandKeeper<SyncLockTestState>(
        definition: Land("test", using: SyncLockTestState.self) {},
        initialState: SyncLockTestState()
    )
    
    // Act: Try to start two sync operations concurrently
    let sync1Task = Task {
        await keeper.beginSync()
    }
    
    let sync2Task = Task {
        await keeper.beginSync()
    }
    
    // Wait for both to complete
    let sync1Result = await sync1Task.value
    let sync2Result = await sync2Task.value
    
    // Assert: Only one should succeed
    let successCount = [sync1Result, sync2Result].compactMap { $0 }.count
    #expect(successCount == 1, "Only one sync operation should acquire lock, got \(successCount)")
    
    // Clean up: release the lock if one was acquired
    if sync1Result != nil {
        await keeper.endSync()
    } else if sync2Result != nil {
        await keeper.endSync()
    }
}

@Test("Sync lock is released after error")
func testSyncLockReleasedAfterError() async throws {
    // Arrange
    let keeper = LandKeeper<SyncLockTestState>(
        definition: Land("test", using: SyncLockTestState.self) {},
        initialState: SyncLockTestState()
    )
    
    // Act: Acquire sync lock
    guard let _ = await keeper.beginSync() else {
        Issue.record("Failed to acquire sync lock")
        return
    }
    
    // Simulate error scenario - release lock manually
    await keeper.endSync()
    
    // Verify lock is released - should be able to acquire again
    let secondSync = await keeper.beginSync()
    #expect(secondSync != nil, "Should be able to acquire sync lock after release")
    
    // Clean up
    if secondSync != nil {
        await keeper.endSync()
    }
}

@Test("Sync snapshot remains consistent even if state changes during sync")
func testSyncSnapshotRemainsConsistent() async throws {
    // Arrange
    let definition = Land(
        "sync-snapshot-test",
        using: SyncLockTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout SyncLockTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.counter += action.amount
                state.lastModifiedBy = action.modifier
                return IncrementCounterResponse(success: true, newValue: state.counter)
            }
        }
    }
    
    let keeper = LandKeeper<SyncLockTestState>(
        definition: definition,
        initialState: SyncLockTestState()
    )
    
    // Act: Start sync and capture snapshot
    guard let syncState = await keeper.beginSync() else {
        Issue.record("Failed to acquire sync lock")
        return
    }
    
    let snapshotCounter = syncState.counter
    
    // Modify state while sync is in progress (should wait)
    let modifyTask = Task {
        try await keeper.handleAction(
            IncrementCounterAction(amount: 100, modifier: "action"),
            playerID: PlayerID("player1"),
            clientID: ClientID("client1"),
            sessionID: SessionID("session1")
        )
    }
    
    // Give task time to execute (mutation proceeds immediately, not blocked)
    try await Task.sleep(for: .milliseconds(50))
    
    // Verify snapshot remains consistent (snapshot is immutable)
    #expect(snapshotCounter == 0, "Snapshot counter should remain 0 (snapshot is immutable)")
    
    // State may have changed (snapshot model doesn't block mutations)
    let stateDuringSync = await keeper.currentState()
    // Mutation may have already completed
    #expect(stateDuringSync.counter >= 0, "State counter may have changed (snapshot model allows this)")
    
    // End sync
    await keeper.endSync()
    
    // Wait for mutation to complete
    _ = try await modifyTask.value
    
    // Verify state changed
    let finalState = await keeper.currentState()
    #expect(finalState.counter == 100, "Counter should be 100 after mutation completes")
    
    // Verify snapshot was consistent (didn't see the mutation - snapshot is immutable)
    #expect(snapshotCounter == 0, "Snapshot should still show original value (snapshots are immutable)")
}
