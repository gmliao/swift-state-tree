// Tests/SwiftStateTreeTests/LandKeeperTickSyncTests.swift
//
// Tests for tick-based synchronization with multiple players
// Verifies that tick updates are correctly synced to all players
// and that broadcast and per-player data formats are consistent

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test State with Broadcast and Per-Player Fields

@StateNodeBuilder
struct TickTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var gameTime: Int = 0
    
    @Sync(.perPlayerSlice())
    var playerScores: [PlayerID: Int] = [:]
    
    @Sync(.perPlayerSlice())
    var playerItems: [PlayerID: [String]] = [:]
}

// MARK: - Tests

@Test("Broadcast and per-player snapshots use same format")
func testBroadcastAndPerPlayerSnapshotFormat() async throws {
    let alice = PlayerID("alice")
    
    var state = TickTestState()
    state.ticks = 10
    state.gameTime = 100
    state.playerScores[alice] = 50
    state.playerItems[alice] = ["sword", "shield"]
    
    let syncEngine = SyncEngine()
    
    // Extract broadcast snapshot
    let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
    
    // Extract per-player snapshot
    let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: alice, from: state)
    
    // Verify broadcast snapshot contains broadcast fields
    #expect(broadcastSnapshot.values["ticks"] != nil, "Broadcast snapshot should contain ticks")
    #expect(broadcastSnapshot.values["gameTime"] != nil, "Broadcast snapshot should contain gameTime")
    #expect(broadcastSnapshot.values["playerScores"] == nil, "Broadcast snapshot should not contain playerScores")
    #expect(broadcastSnapshot.values["playerItems"] == nil, "Broadcast snapshot should not contain playerItems")
    
    // Verify per-player snapshot contains per-player fields
    #expect(perPlayerSnapshot.values["playerScores"] != nil, "Per-player snapshot should contain playerScores")
    #expect(perPlayerSnapshot.values["playerItems"] != nil, "Per-player snapshot should contain playerItems")
    #expect(perPlayerSnapshot.values["ticks"] == nil, "Per-player snapshot should not contain ticks")
    #expect(perPlayerSnapshot.values["gameTime"] == nil, "Per-player snapshot should not contain gameTime")
    
    // Verify both use the same SnapshotValue format
    #expect(broadcastSnapshot.values["ticks"] != nil, "Broadcast ticks should exist")
    #expect(perPlayerSnapshot.values["playerScores"] != nil, "Per-player scores should exist")
}

@Test("Tick updates broadcast fields and generates same patches for all players")
func testTickUpdatesBroadcastFields() async throws {
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    let definition = Land(
        "tick-sync-test",
        using: TickTestState.self
    ) {
        Rules { }
        
        Lifetime { (config: inout LifetimeConfig<TickTestState>) in
            config.tickInterval = .milliseconds(50)
            config.tickHandler = { state, _ in
                state.ticks += 1
                state.gameTime += 1
            }
        }
    }
    
    let keeper = LandKeeper<TickTestState>(
        definition: definition,
        initialState: TickTestState()
    )
    
    // Join players
    try await keeper.join(playerID: alice, clientID: ClientID("alice-client"), sessionID: SessionID("alice-session"))
    try await keeper.join(playerID: bob, clientID: ClientID("bob-client"), sessionID: SessionID("bob-session"))
    
    // Wait for at least 3 ticks
    await waitFor("Ticks should increment", timeout: .seconds(1)) {
        let state = await keeper.currentState()
        return state.ticks >= 3
    }
    
    // Verify state was updated
    let finalState = await keeper.currentState()
    #expect(finalState.ticks >= 3, "Ticks should have incremented")
    #expect(finalState.gameTime >= 3, "Game time should have incremented")
    
    // Now manually test sync to verify broadcast fields are the same
    // First, populate cache for both players
    var syncEngineAlice = SyncEngine()
    var syncEngineBob = SyncEngine()
    let state = await keeper.currentState()
    
    // First sync for alice (populates cache)
    _ = try syncEngineAlice.generateDiff(for: alice, from: state)
    
    // First sync for bob (populates cache)
    _ = try syncEngineBob.generateDiff(for: bob, from: state)
    
    // Wait a bit more for another tick to generate actual diffs
    try? await Task.sleep(for: .milliseconds(100))
    let stateAfterTick = await keeper.currentState()
    
    // Now generate diffs - these should have patches
    let aliceUpdate = try syncEngineAlice.generateDiff(for: alice, from: stateAfterTick)
    let bobUpdate = try syncEngineBob.generateDiff(for: bob, from: stateAfterTick)
    
    // Extract patches from StateUpdate enum
    let alicePatches: [StatePatch]
    let bobPatches: [StatePatch]
    
    switch aliceUpdate {
    case .firstSync(let patches), .diff(let patches):
        alicePatches = patches
    case .noChange:
        alicePatches = []
    }
    
    switch bobUpdate {
    case .firstSync(let patches), .diff(let patches):
        bobPatches = patches
    case .noChange:
        bobPatches = []
    }
    
    // Verify both players have ticks patches
    let aliceTicksPatch = alicePatches.first { $0.path == "/ticks" }
    let bobTicksPatch = bobPatches.first { $0.path == "/ticks" }
    
    #expect(aliceTicksPatch != nil, "Alice should have ticks patch")
    #expect(bobTicksPatch != nil, "Bob should have ticks patch")
    
    // Verify ticks values are the same (broadcast should be identical)
    if case .set(let aliceTicksValue) = aliceTicksPatch?.operation,
       case .set(let bobTicksValue) = bobTicksPatch?.operation {
        #expect(aliceTicksValue == bobTicksValue, "Broadcast ticks should be the same for both players")
    }
    
    // Verify gameTime patches are the same
    let aliceGameTimePatch = alicePatches.first { $0.path == "/gameTime" }
    let bobGameTimePatch = bobPatches.first { $0.path == "/gameTime" }
    
    if let aliceGameTimePatch = aliceGameTimePatch,
       let bobGameTimePatch = bobGameTimePatch {
        if case .set(let aliceGameTimeValue) = aliceGameTimePatch.operation,
           case .set(let bobGameTimeValue) = bobGameTimePatch.operation {
            #expect(aliceGameTimeValue == bobGameTimeValue, "Broadcast gameTime should be the same for both players")
        }
    }
}

// MARK: - Helper Function

func waitFor(
    _ description: String,
    timeout: Duration = .seconds(5),
    condition: @escaping () async -> Bool
) async {
    let startTime = ContinuousClock.now
    let timeoutInstant = startTime + timeout
    
    while ContinuousClock.now < timeoutInstant {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    
    Issue.record("Timeout waiting for: \(description)")
}
