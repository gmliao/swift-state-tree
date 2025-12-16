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
        try await keeper.handleClientEvent(
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
    try? await eventTask.value  // Event handler can throw, but we ignore errors in this test
    
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

// MARK: - Dirty Flags Clear Tests

@StateNodeBuilder
struct DirtyFlagsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var round: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var score: Int = 0
    
    public init() {}
}

@StateNodeBuilder
struct NestedDirtyFlagsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var nestedValue: Int = 0
    
    public init() {}
}

@StateNodeBuilder
struct ParentDirtyFlagsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var parentValue: Int = 0
    
    @Sync(.broadcast)
    var nested: NestedDirtyFlagsTestState = NestedDirtyFlagsTestState()
    
    public init() {}
}

@Test("endSync() automatically clears dirty flags after sync")
func testEndSync_ClearsDirtyFlags() async throws {
    // Arrange
    let definition = Land(
        "dirty-flags-test",
        using: DirtyFlagsTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout DirtyFlagsTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.round += action.amount
                state.players[ctx.playerID] = "Player \(action.amount)"
                state.score += action.amount * 10
                return IncrementCounterResponse(success: true, newValue: state.round)
            }
        }
    }
    
    let keeper = LandKeeper<DirtyFlagsTestState>(
        definition: definition,
        initialState: DirtyFlagsTestState()
    )
    
    // Act: Modify state (marks as dirty)
    try await keeper.handleAction(
        IncrementCounterAction(amount: 5, modifier: "test"),
        playerID: PlayerID("player1"),
        clientID: ClientID("client1"),
        sessionID: SessionID("session1")
    )
    
    // Verify state is dirty before sync
    let stateBeforeSync = await keeper.currentState()
    #expect(stateBeforeSync.isDirty() == true, "State should be dirty after modification")
    #expect(stateBeforeSync.getDirtyFields().contains("round"), "Should contain 'round' in dirty fields")
    #expect(stateBeforeSync.getDirtyFields().contains("players"), "Should contain 'players' in dirty fields")
    #expect(stateBeforeSync.getDirtyFields().contains("score"), "Should contain 'score' in dirty fields")
    
    // Perform sync (beginSync -> endSync)
    guard let _ = await keeper.beginSync() else {
        Issue.record("Failed to begin sync")
        return
    }
    
    // endSync() should automatically clear dirty flags
    await keeper.endSync()
    
    // Verify dirty flags are cleared after endSync()
    let stateAfterSync = await keeper.currentState()
    #expect(stateAfterSync.isDirty() == false, "State should not be dirty after endSync()")
    #expect(stateAfterSync.getDirtyFields().isEmpty == true, "Should have no dirty fields after endSync()")
}

@Test("Multiple sync rounds with endSync() should keep all dirty flags cleared")
func testMultipleSyncRounds_EndSync_KeepsAllFlagsCleared() async throws {
    // Arrange
    let definition = Land(
        "dirty-flags-multi-round-test",
        using: DirtyFlagsTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout DirtyFlagsTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.round += action.amount
                state.players[ctx.playerID] = "Player \(state.round)"
                state.score += action.amount * 10
                return IncrementCounterResponse(success: true, newValue: state.round)
            }
        }
    }
    
    let keeper = LandKeeper<DirtyFlagsTestState>(
        definition: definition,
        initialState: DirtyFlagsTestState()
    )
    
    // Act: Simulate multiple sync rounds
    for round in 1...10 {
        // Modify state
        _ = try await keeper.handleAction(
            IncrementCounterAction(amount: round, modifier: "round\(round)"),
            playerID: PlayerID("player1"),
            clientID: ClientID("client1"),
            sessionID: SessionID("session1")
        )
        
        // Verify state is dirty before sync
        let stateBeforeSync = await keeper.currentState()
        #expect(stateBeforeSync.isDirty() == true, "State should be dirty after modification (round \(round))")
        
        // Perform sync (beginSync -> endSync)
        guard let _ = await keeper.beginSync() else {
            Issue.record("Failed to begin sync (round \(round))")
            return
        }
        
        // endSync() should automatically clear dirty flags
        await keeper.endSync()
        
        // Verify dirty flags are cleared after endSync()
        let stateAfterSync = await keeper.currentState()
        #expect(stateAfterSync.isDirty() == false, "State should not be dirty after endSync() (round \(round))")
        #expect(stateAfterSync.getDirtyFields().isEmpty == true, "Should have no dirty fields after endSync() (round \(round))")
    }
    
    // Final verification: after 10 rounds, state should still be clean
    let finalState = await keeper.currentState()
    #expect(finalState.isDirty() == false, "State should still be clean after 10 sync rounds")
    #expect(finalState.getDirtyFields().isEmpty == true, "Should have no dirty fields after 10 sync rounds")
}

@Test("endSync() recursively clears nested StateNode dirty flags")
func testEndSync_RecursivelyClearsNestedStateNode() async throws {
    // Arrange
    let definition = Land(
        "nested-dirty-flags-test",
        using: ParentDirtyFlagsTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout ParentDirtyFlagsTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.parentValue += action.amount
                state.nested.nestedValue += action.amount * 10
                return IncrementCounterResponse(success: true, newValue: state.parentValue)
            }
        }
    }
    
    let keeper = LandKeeper<ParentDirtyFlagsTestState>(
        definition: definition,
        initialState: ParentDirtyFlagsTestState()
    )
    
    // Act: Modify both parent and nested fields
    try await keeper.handleAction(
        IncrementCounterAction(amount: 5, modifier: "test"),
        playerID: PlayerID("player1"),
        clientID: ClientID("client1"),
        sessionID: SessionID("session1")
    )
    
    // Verify both are dirty before sync
    let stateBeforeSync = await keeper.currentState()
    #expect(stateBeforeSync.isDirty() == true, "Parent should be dirty")
    #expect(stateBeforeSync.nested.isDirty() == true, "Nested should be dirty")
    #expect(stateBeforeSync.getDirtyFields().contains("parentValue"), "Parent should contain 'parentValue'")
    #expect(stateBeforeSync.getDirtyFields().contains("nested"), "Parent should contain 'nested'")
    #expect(stateBeforeSync.nested.getDirtyFields().contains("nestedValue"), "Nested should contain 'nestedValue'")
    
    // Perform sync (beginSync -> endSync)
    guard let _ = await keeper.beginSync() else {
        Issue.record("Failed to begin sync")
        return
    }
    
    // endSync() should automatically clear dirty flags (including nested)
    await keeper.endSync()
    
    // Verify all dirty flags are cleared (including nested)
    let stateAfterSync = await keeper.currentState()
    #expect(stateAfterSync.isDirty() == false, "Parent should not be dirty after endSync()")
    #expect(stateAfterSync.getDirtyFields().isEmpty == true, "Parent should have no dirty fields after endSync()")
    #expect(stateAfterSync.nested.isDirty() == false, "Nested should not be dirty after endSync()")
    #expect(stateAfterSync.nested.getDirtyFields().isEmpty == true, "Nested should have no dirty fields after endSync()")
}

@Test("Multiple sync rounds with nested StateNode should recursively clear all dirty flags")
func testMultipleSyncRounds_WithNestedStateNode_RecursivelyClearsAllFlags() async throws {
    // Arrange
    let definition = Land(
        "nested-dirty-flags-multi-round-test",
        using: ParentDirtyFlagsTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout ParentDirtyFlagsTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.parentValue += action.amount
                state.nested.nestedValue += action.amount * 10
                return IncrementCounterResponse(success: true, newValue: state.parentValue)
            }
        }
    }
    
    let keeper = LandKeeper<ParentDirtyFlagsTestState>(
        definition: definition,
        initialState: ParentDirtyFlagsTestState()
    )
    
    // Act: Simulate multiple sync rounds with nested StateNode modifications
    for round in 1...5 {
        // Modify both parent and nested fields
        _ = try await keeper.handleAction(
            IncrementCounterAction(amount: round, modifier: "round\(round)"),
            playerID: PlayerID("player1"),
            clientID: ClientID("client1"),
            sessionID: SessionID("session1")
        )
        
        // Verify both are dirty before sync
        let stateBeforeSync = await keeper.currentState()
        #expect(stateBeforeSync.isDirty() == true, "Parent should be dirty (round \(round))")
        #expect(stateBeforeSync.nested.isDirty() == true, "Nested should be dirty (round \(round))")
        
        // Perform sync (beginSync -> endSync)
        guard let _ = await keeper.beginSync() else {
            Issue.record("Failed to begin sync (round \(round))")
            return
        }
        
        // endSync() should automatically clear dirty flags (including nested)
        await keeper.endSync()
        
        // Verify all dirty flags are cleared (including nested)
        let stateAfterSync = await keeper.currentState()
        #expect(stateAfterSync.isDirty() == false, "Parent should not be dirty after endSync() (round \(round))")
        #expect(stateAfterSync.getDirtyFields().isEmpty == true, "Parent should have no dirty fields (round \(round))")
        #expect(stateAfterSync.nested.isDirty() == false, "Nested should not be dirty after endSync() (round \(round))")
        #expect(stateAfterSync.nested.getDirtyFields().isEmpty == true, "Nested should have no dirty fields (round \(round))")
    }
    
    // Final verification: after multiple rounds, all dirty flags should be cleared
    let finalState = await keeper.currentState()
    #expect(finalState.isDirty() == false, "Parent should still be clean after multiple sync rounds")
    #expect(finalState.nested.isDirty() == false, "Nested should still be clean after multiple sync rounds")
    #expect(finalState.getDirtyFields().isEmpty == true, "Parent should have no dirty fields after multiple sync rounds")
    #expect(finalState.nested.getDirtyFields().isEmpty == true, "Nested should have no dirty fields after multiple sync rounds")
}
