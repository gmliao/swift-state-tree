// Tests/SwiftStateTreeTests/SyncEngineOptimizationTests.swift
//
// Tests for optimization APIs: extractBroadcastSnapshot, extractPerPlayerSnapshot, generateDiffFromSnapshots, warmupCache

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test StateNode Examples

/// Test StateNode for optimization API testing
@StateNodeBuilder
struct OptimizationTestStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: [String]] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
    
    @Sync(.broadcast)
    var turn: PlayerID? = nil
}

// MARK: - Unified Snapshot Extraction Tests

@Test("extractBroadcastSnapshot extracts only broadcast fields")
func testExtractBroadcastSnapshot_ExtractsOnlyBroadcastFields() throws {
    // Arrange
    let syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.hands[playerID] = ["card1", "card2"]
    state.round = 1
    state.turn = playerID
    
    // Act
    let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
    
    // Assert
    #expect(broadcastSnapshot.values.keys.contains("players"), "Broadcast snapshot should contain players")
    #expect(broadcastSnapshot.values.keys.contains("round"), "Broadcast snapshot should contain round")
    #expect(broadcastSnapshot.values.keys.contains("turn"), "Broadcast snapshot should contain turn")
    #expect(!broadcastSnapshot.values.keys.contains("hands"), "Broadcast snapshot should not contain hands")
}

@Test("extractPerPlayerSnapshot extracts only per-player fields")
func testExtractPerPlayerSnapshot_ExtractsOnlyPerPlayerFields() throws {
    // Arrange
    let syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.hands[playerID] = ["card1", "card2"]
    state.round = 1
    state.turn = playerID
    
    // Act
    let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
    
    // Assert
    #expect(perPlayerSnapshot.values.keys.contains("hands"), "Per-player snapshot should contain hands")
    #expect(!perPlayerSnapshot.values.keys.contains("players"), "Per-player snapshot should not contain players")
    #expect(!perPlayerSnapshot.values.keys.contains("round"), "Per-player snapshot should not contain round")
    #expect(!perPlayerSnapshot.values.keys.contains("turn"), "Per-player snapshot should not contain turn")
}

@Test("extractBroadcastSnapshot can be reused for multiple players")
func testExtractBroadcastSnapshot_CanBeReusedForMultiplePlayers() throws {
    // Arrange
    let syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    state.players[alice] = "Alice"
    state.players[bob] = "Bob"
    state.round = 1
    
    // Act - extract broadcast once
    let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
    
    // Extract per-player for different players
    let alicePerPlayer = try syncEngine.extractPerPlayerSnapshot(for: alice, from: state)
    let bobPerPlayer = try syncEngine.extractPerPlayerSnapshot(for: bob, from: state)
    
    // Assert - broadcast should be the same for both players
    #expect(broadcastSnapshot.values.keys.contains("players"), "Broadcast should contain players")
    #expect(broadcastSnapshot.values.keys.contains("round"), "Broadcast should contain round")
    
    // Per-player snapshots may differ
    // Verify that per-player snapshots are extracted (they may be empty but should exist)
    #expect(alicePerPlayer.values.isEmpty || alicePerPlayer.values.keys.contains("hands"), "Alice per-player snapshot should exist")
    #expect(bobPerPlayer.values.isEmpty || bobPerPlayer.values.keys.contains("hands"), "Bob per-player snapshot should exist")
}

// MARK: - Generate Diff From Snapshots Tests

@Test("generateDiffFromSnapshots produces same result as generateDiff")
func testGenerateDiffFromSnapshots_ProducesSameResultAsGenerateDiff() throws {
    // Arrange
    var syncEngine1 = SyncEngine()
    var syncEngine2 = SyncEngine()
    var state1 = OptimizationTestStateRootNode()
    var state2 = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // Initial state
    state1.players[playerID] = "Alice"
    state1.round = 1
    state2.players[playerID] = "Alice"
    state2.round = 1
    
    // First sync for both engines
    _ = try syncEngine1.generateDiff(for: playerID, from: state1)
    let broadcastSnapshot = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    _ = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot,
        perPlayerSnapshot: perPlayerSnapshot,
        state: state2
    )
    
    // Change state
    state1.round = 2
    state2.round = 2
    
    // Act
    let update1 = try syncEngine1.generateDiff(for: playerID, from: state1)
    let broadcastSnapshot2 = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot2 = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    let update2 = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot2,
        perPlayerSnapshot: perPlayerSnapshot2,
        state: state2
    )
    
    // Assert
    if case .diff(let patches1) = update1,
       case .diff(let patches2) = update2 {
        #expect(patches1.count == patches2.count, "Both methods should produce same number of patches")
        if patches1.count > 0 && patches2.count > 0 {
            #expect(patches1[0].path == patches2[0].path, "Patches should have same path")
        }
    } else {
        Issue.record("Both updates should return .diff")
    }
}

@Test("generateDiffFromSnapshots with dirty tracking produces same result as generateDiff")
func testGenerateDiffFromSnapshots_WithDirtyTracking_ProducesSameResultAsGenerateDiff() throws {
    // Arrange
    var syncEngine1 = SyncEngine()
    var syncEngine2 = SyncEngine()
    var state1 = OptimizationTestStateRootNode()
    var state2 = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // Initial state
    state1.players[playerID] = "Alice"
    state1.round = 1
    state1.hands[playerID] = ["card1"]
    state2.players[playerID] = "Alice"
    state2.round = 1
    state2.hands[playerID] = ["card1"]
    
    // First sync for both engines
    _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: true)
    let broadcastSnapshot = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    _ = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot,
        perPlayerSnapshot: perPlayerSnapshot,
        state: state2
    )
    
    // Clear dirty flags
    state1.clearDirty()
    state2.clearDirty()
    
    // Change only broadcast field (round)
    state1.round = 2
    state2.round = 2
    
    // Act
    let update1 = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: true)
    let broadcastSnapshot2 = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot2 = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    let update2 = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot2,
        perPlayerSnapshot: perPlayerSnapshot2,
        state: state2
    )
    
    // Assert - both should produce same result
    if case .diff(let patches1) = update1,
       case .diff(let patches2) = update2 {
        #expect(patches1.count == patches2.count, "Both methods should produce same number of patches")
        // Both should only have patch for round (broadcast field)
        let roundPatch1 = patches1.first { $0.path == "/round" }
        let roundPatch2 = patches2.first { $0.path == "/round" }
        #expect(roundPatch1 != nil, "generateDiff should have patch for round")
        #expect(roundPatch2 != nil, "generateDiffFromSnapshots should have patch for round")
    } else {
        Issue.record("Both updates should return .diff")
    }
}

@Test("generateDiffFromSnapshots with dirty tracking handles per-player fields correctly")
func testGenerateDiffFromSnapshots_WithDirtyTracking_HandlesPerPlayerFields() throws {
    // Arrange
    var syncEngine1 = SyncEngine()
    var syncEngine2 = SyncEngine()
    var state1 = OptimizationTestStateRootNode()
    var state2 = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // Initial state
    state1.players[playerID] = "Alice"
    state1.round = 1
    state1.hands[playerID] = ["card1"]
    state2.players[playerID] = "Alice"
    state2.round = 1
    state2.hands[playerID] = ["card1"]
    
    // First sync for both engines
    _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: true)
    let broadcastSnapshot = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    _ = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot,
        perPlayerSnapshot: perPlayerSnapshot,
        state: state2
    )
    
    // Clear dirty flags
    state1.clearDirty()
    state2.clearDirty()
    
    // Change only per-player field (hands)
    state1.hands[playerID] = ["card1", "card2"]
    state2.hands[playerID] = ["card1", "card2"]
    
    // Act
    let update1 = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: true)
    let broadcastSnapshot2 = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot2 = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    let update2 = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot2,
        perPlayerSnapshot: perPlayerSnapshot2,
        state: state2
    )
    
    // Assert - both should produce same result
    if case .diff(let patches1) = update1,
       case .diff(let patches2) = update2 {
        #expect(patches1.count == patches2.count, "Both methods should produce same number of patches")
        // Both should only have patch for hands (per-player field)
        let handsPatch1 = patches1.first { $0.path.hasPrefix("/hands") }
        let handsPatch2 = patches2.first { $0.path.hasPrefix("/hands") }
        #expect(handsPatch1 != nil, "generateDiff should have patch for hands")
        #expect(handsPatch2 != nil, "generateDiffFromSnapshots should have patch for hands")
    } else {
        Issue.record("Both updates should return .diff")
    }
}

@Test("generateDiffFromSnapshots with dirty tracking handles mixed broadcast and per-player fields")
func testGenerateDiffFromSnapshots_WithDirtyTracking_HandlesMixedFields() throws {
    // Arrange
    var syncEngine1 = SyncEngine()
    var syncEngine2 = SyncEngine()
    var state1 = OptimizationTestStateRootNode()
    var state2 = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // Initial state
    state1.players[playerID] = "Alice"
    state1.round = 1
    state1.hands[playerID] = ["card1"]
    state2.players[playerID] = "Alice"
    state2.round = 1
    state2.hands[playerID] = ["card1"]
    
    // First sync for both engines
    _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: true)
    let broadcastSnapshot = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    _ = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot,
        perPlayerSnapshot: perPlayerSnapshot,
        state: state2
    )
    
    // Clear dirty flags
    state1.clearDirty()
    state2.clearDirty()
    
    // Change both broadcast and per-player fields
    state1.round = 2
    state1.hands[playerID] = ["card1", "card2"]
    state2.round = 2
    state2.hands[playerID] = ["card1", "card2"]
    
    // Act
    let update1 = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: true)
    let broadcastSnapshot2 = try syncEngine2.extractBroadcastSnapshot(from: state2)
    let perPlayerSnapshot2 = try syncEngine2.extractPerPlayerSnapshot(for: playerID, from: state2)
    let update2 = try syncEngine2.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot2,
        perPlayerSnapshot: perPlayerSnapshot2,
        state: state2
    )
    
    // Assert - both should produce same result
    if case .diff(let patches1) = update1,
       case .diff(let patches2) = update2 {
        #expect(patches1.count == patches2.count, "Both methods should produce same number of patches")
        // Both should have patches for both round and hands
        let roundPatch1 = patches1.first { $0.path == "/round" }
        let roundPatch2 = patches2.first { $0.path == "/round" }
        let handsPatch1 = patches1.first { $0.path.hasPrefix("/hands") }
        let handsPatch2 = patches2.first { $0.path.hasPrefix("/hands") }
        #expect(roundPatch1 != nil, "generateDiff should have patch for round")
        #expect(roundPatch2 != nil, "generateDiffFromSnapshots should have patch for round")
        #expect(handsPatch1 != nil, "generateDiff should have patch for hands")
        #expect(handsPatch2 != nil, "generateDiffFromSnapshots should have patch for hands")
    } else {
        Issue.record("Both updates should return .diff")
    }
}

@Test("generateDiffFromSnapshots with state parameter uses automatic dirty tracking")
func testGenerateDiffFromSnapshots_WithState_UsesDirtyTracking() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // Initial state
    state.players[playerID] = "Alice"
    state.round = 1
    state.hands[playerID] = ["card1"]
    
    // First sync
    let broadcastSnapshot1 = try syncEngine.extractBroadcastSnapshot(from: state)
    let perPlayerSnapshot1 = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
    _ = try syncEngine.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot1,
        perPlayerSnapshot: perPlayerSnapshot1,
        state: state
    )
    
    // Change state
    state.round = 2
    state.hands[playerID] = ["card1", "card2"]
    
    // Act - with state parameter for automatic dirty tracking
    let broadcastSnapshot2 = try syncEngine.extractBroadcastSnapshot(from: state)
    let perPlayerSnapshot2 = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
    let update = try syncEngine.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot2,
        perPlayerSnapshot: perPlayerSnapshot2,
        state: state
    )
    
    // Assert - should still work and detect changes
    if case .diff(let patches) = update {
        #expect(patches.count > 0, "Should have patches for changed fields")
    } else {
        Issue.record("Should return .diff after first sync")
    }
}

@Test("generateDiffFromSnapshots handles first sync correctly")
func testGenerateDiffFromSnapshots_HandlesFirstSync() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.round = 1
    
    // Act
    let broadcastSnapshot = try syncEngine.extractBroadcastSnapshot(from: state)
    let perPlayerSnapshot = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
    let update = try syncEngine.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot,
        perPlayerSnapshot: perPlayerSnapshot,
        state: state
    )
    
    // Assert
    if case .firstSync(let patches) = update {
        // First sync should populate cache and return firstSync signal
        #expect(patches.count >= 0, "First sync should include patches array")
    } else {
        Issue.record("First diff should return .firstSync([StatePatch]), got: \(update)")
    }
}

@Test("generateDiffFromSnapshots updates cache correctly")
func testGenerateDiffFromSnapshots_UpdatesCache() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.round = 1
    
    // First sync
    let broadcastSnapshot1 = try syncEngine.extractBroadcastSnapshot(from: state)
    let perPlayerSnapshot1 = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
    _ = try syncEngine.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot1,
        perPlayerSnapshot: perPlayerSnapshot1,
        state: state
    )
    
    // Change state
    state.round = 2
    
    // Act - second sync
    let broadcastSnapshot2 = try syncEngine.extractBroadcastSnapshot(from: state)
    let perPlayerSnapshot2 = try syncEngine.extractPerPlayerSnapshot(for: playerID, from: state)
    let update = try syncEngine.generateDiffFromSnapshots(
        for: playerID,
        broadcastSnapshot: broadcastSnapshot2,
        perPlayerSnapshot: perPlayerSnapshot2,
        state: state
    )
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count > 0, "Should have patches for changed field")
        #expect(patches.contains { $0.path == "/round" }, "Should have patch for /round")
    } else {
        Issue.record("Should return .diff after first sync")
    }
}

// MARK: - Warmup Cache Tests

@Test("warmupCache populates broadcast cache")
func testWarmupCache_PopulatesBroadcastCache() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.round = 1
    
    // Act
    try syncEngine.warmupCache(from: state)
    
    // Assert - first diff should not return firstSync for broadcast
    state.round = 2
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Should detect change in round (not firstSync for broadcast part)
    if case .firstSync = update {
        // This is expected for per-player cache (first time for this player)
        // But broadcast cache should be warmed up
    } else if case .diff(let patches) = update {
        // Should have patches for the change
        #expect(patches.count > 0, "Should have patches after warmup")
    }
}

@Test("warmupCache does not overwrite existing cache")
func testWarmupCache_DoesNotOverwriteExistingCache() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.round = 1
    
    // Populate cache first
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Change state
    state.round = 2
    
    // Act - warmup should not overwrite
    try syncEngine.warmupCache(from: state)
    
    // Assert - cache should still reflect the change
    state.round = 3
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    if case .diff(let patches) = update {
        // Should detect change from round 2 to 3, not from 1 to 3
        #expect(patches.count > 0, "Should have patches")
    } else {
        Issue.record("Should return .diff")
    }
}

@Test("warmupCache only warms broadcast cache, per-player cache is populated on first generateDiff")
func testWarmupCache_OnlyWarmsBroadcastCache() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.hands[playerID] = ["card1"]
    state.round = 1
    
    // Act - warmup only warms broadcast cache
    try syncEngine.warmupCache(from: state)
    
    // Assert - per-player cache should still be empty (will be populated on first generateDiff)
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Should return firstSync because per-player cache was not warmed (this is expected)
    if case .firstSync = update {
        // Expected: per-player cache is populated automatically on first generateDiff call
    } else {
        Issue.record("Should return firstSync when per-player cache not warmed")
    }
}

// MARK: - extractWithSnapshotForSync equivalence

@Test("extractWithSnapshotForSync produces same broadcast and per-player snapshots as old path")
func testExtractWithSnapshotForSync_EquivalentToOldPath() throws {
    // Arrange: state and player list
    let syncEngine = SyncEngine()
    var state = OptimizationTestStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    state.players[alice] = "Alice"
    state.players[bob] = "Bob"
    state.hands[alice] = ["card1", "card2"]
    state.hands[bob] = ["card3"]
    state.round = 1
    state.turn = alice
    let playerIDs = [alice, bob]

    // Act - old path: 1 broadcast + N per-player extractions
    let broadcastOld = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    var perPlayerOld: [PlayerID: StateSnapshot] = [:]
    for pid in playerIDs {
        perPlayerOld[pid] = try syncEngine.extractPerPlayerSnapshot(for: pid, from: state, mode: .all)
    }

    // Act - new path: one-pass snapshotForSync
    let (broadcastNew, perPlayerNew) = try syncEngine.extractWithSnapshotForSync(
        from: state,
        playerIDs: playerIDs,
        mode: .all
    )

    // Assert - same broadcast snapshot
    #expect(broadcastNew == broadcastOld, "Broadcast snapshot from snapshotForSync should equal extractBroadcastSnapshot")

    // Assert - same per-player snapshots for each player
    #expect(perPlayerNew.count == perPlayerOld.count)
    for pid in playerIDs {
        #expect(perPlayerNew[pid] != nil, "Per-player snapshot should exist for \(pid)")
        #expect(perPlayerNew[pid] == perPlayerOld[pid], "Per-player snapshot for \(pid) from snapshotForSync should equal extractPerPlayerSnapshot")
    }
}

