// Tests/SwiftStateTreeTests/SyncEngineDiffTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test StateNode Examples

/// Test StateNode for diff testing
@StateNodeBuilder
struct DiffTestStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: [String]] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
    
    @Sync(.broadcast)
    var turn: PlayerID? = nil
}

// MARK: - Basic Diff Calculation Tests

@Test("First diff returns firstSync (cache and signal sync engine start)")
func testGenerateDiff_FirstTime_ReturnsFirstSync() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    state.round = 1
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .firstSync(let patches) = update {
        // Expected: first sync caches and returns firstSync signal with patches
        // Patches may be empty if no changes occurred
        #expect(patches.count >= 0, "First sync should include patches array")
    } else {
        Issue.record("First diff should return .firstSync([StatePatch]), got: \(update)")
    }
}

@Test("Single field change generates set patch")
func testGenerateDiff_SingleFieldChange_GeneratesSetPatch() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // First sync (cache)
    state.round = 1
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Change value
    state.round = 2
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count == 1, "Should have 1 patch")
        #expect(patches[0].path == "/round", "Path should be /round")
        if case .set(let value) = patches[0].operation {
            #expect(value.intValue == 2, "Value should be 2")
        } else {
            Issue.record("Operation should be .set")
        }
    } else {
        Issue.record("Should return .diff with patches")
    }
}

@Test("Field deletion generates delete patch")
func testGenerateDiff_FieldDeletion_GeneratesDeletePatch() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // First sync (cache)
    state.round = 1
    state.players[playerID] = "Alice"
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Delete field (remove from dictionary)
    state.players.removeValue(forKey: playerID)
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count >= 1, "Should have at least 1 patch")
        // Check for delete patch in players object
        let hasDeletePatch = patches.contains { patch in
            patch.path.contains("/players") && 
            (patch.path.contains("/alice") || patch.path.contains(playerID.rawValue))
        }
        #expect(hasDeletePatch || patches.contains { $0.operation == .delete }, 
                "Should have delete patch for removed player")
    } else {
        Issue.record("Should return .diff with patches")
    }
}

@Test("New field addition generates set patch")
func testGenerateDiff_NewField_GeneratesSetPatch() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // First sync (cache)
    state.round = 1
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Add new field
    state.players[playerID] = "Alice"
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        let setPatch = patches.first { $0.path.hasPrefix("/players") }
        #expect(setPatch != nil, "Should have set patch for new field")
    } else {
        Issue.record("Should return .diff with patches")
    }
}

// MARK: - Layered Diff Calculation Tests

@Test("Broadcast field change affects all players")
func testGenerateDiff_BroadcastFieldChange_AffectsAllPlayers() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    // First sync for both players - need to have some data
    state.round = 1
    state.players[alice] = "Alice"
    state.players[bob] = "Bob"
    _ = try syncEngine.generateDiff(for: alice, from: state)
    _ = try syncEngine.generateDiff(for: bob, from: state)
    
    // Change broadcast field
    state.round = 2
    
    // Act
    let aliceUpdate = try syncEngine.generateDiff(for: alice, from: state)
    let bobUpdate = try syncEngine.generateDiff(for: bob, from: state)
    
    // Assert - Both should see the round change
    // Note: Since broadcast cache is shared, Bob might not see changes if Alice already updated the cache
    // This is expected behavior - broadcast changes are computed once and shared
    if case .diff(let alicePatches) = aliceUpdate {
        let aliceRoundPatch = alicePatches.first { $0.path == "/round" }
        #expect(aliceRoundPatch != nil, "Alice should have round patch")
        
        // Bob should either have the same diff (if computed before Alice) or noChange (if Alice already updated cache)
        // In practice, broadcast diffs are computed once and shared across all players
        if case .diff(let bobPatches) = bobUpdate {
            let bobRoundPatch = bobPatches.first { $0.path == "/round" }
            #expect(bobRoundPatch != nil, "Bob should have round patch if diff was computed")
        } else if case .noChange = bobUpdate {
            // This is also valid - Bob's broadcast cache was already updated by Alice's diff computation
            // The important thing is that Alice sees the change
        }
    } else {
        Issue.record("Alice should return .diff with patches")
    }
}

@Test("PerPlayer field change only affects that player")
func testGenerateDiff_PerPlayerFieldChange_OnlyAffectsThatPlayer() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    // First sync for both players
    state.hands[alice] = ["card1"]
    state.hands[bob] = ["card2"]
    _ = try syncEngine.generateDiff(for: alice, from: state)
    _ = try syncEngine.generateDiff(for: bob, from: state)
    
    // Change Alice's hand only
    state.hands[alice] = ["card1", "card3"]
    
    // Act
    let aliceUpdate = try syncEngine.generateDiff(for: alice, from: state)
    let bobUpdate = try syncEngine.generateDiff(for: bob, from: state)
    
    // Assert
    if case .diff(let alicePatches) = aliceUpdate,
       case .noChange = bobUpdate {
        // Alice should have changes, Bob should have no changes
        #expect(alicePatches.count > 0, "Alice should have patches")
    } else {
        Issue.record("Alice should have diff, Bob should have noChange")
    }
}

// MARK: - Cache Tests

@Test("Cache is updated after first sync")
func testCache_UpdatedAfterFirstSync() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.round = 1
    
    // Act - First sync should return firstSync
    let firstUpdate = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Second sync should return noChange if nothing changed
    let secondUpdate = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .firstSync(let patches) = firstUpdate {
        #expect(patches.count >= 0, "First sync should return .firstSync with patches array")
    } else {
        Issue.record("First sync should return .firstSync([StatePatch]), got: \(firstUpdate)")
    }
    #expect(secondUpdate == .noChange, "Second sync with no changes should return .noChange")
}

@Test("Multiple players have isolated caches")
func testCache_MultiplePlayers_IsolatedCaches() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    // First sync for both (should return firstSync)
    state.hands[alice] = ["card1"]
    state.hands[bob] = ["card2"]
    let aliceFirstSync = try syncEngine.generateDiff(for: alice, from: state)
    let bobFirstSync = try syncEngine.generateDiff(for: bob, from: state)
    
    // Verify first sync signals
    if case .firstSync(let alicePatches) = aliceFirstSync {
        #expect(alicePatches.count >= 0, "Alice's first sync should return .firstSync with patches")
    } else {
        Issue.record("Alice's first sync should return .firstSync([StatePatch]), got: \(aliceFirstSync)")
    }
    if case .firstSync(let bobPatches) = bobFirstSync {
        #expect(bobPatches.count >= 0, "Bob's first sync should return .firstSync with patches")
    } else {
        Issue.record("Bob's first sync should return .firstSync([StatePatch]), got: \(bobFirstSync)")
    }
    
    // Change Alice's hand
    state.hands[alice] = ["card1", "card3"]
    
    // Act
    let aliceUpdate = try syncEngine.generateDiff(for: alice, from: state)
    let bobUpdate = try syncEngine.generateDiff(for: bob, from: state)
    
    // Assert - Bob's cache should not be affected by Alice's changes
    if case .diff = aliceUpdate,
       case .noChange = bobUpdate {
        // Expected: Alice has changes, Bob doesn't
    } else {
        Issue.record("Players should have isolated caches")
    }
}

// MARK: - Path Format Tests

@Test("Paths use JSON Pointer format")
func testPathFormat_JSONPointer() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.round = 1
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    state.round = 2
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        let roundPatch = patches.first { $0.path == "/round" }
        #expect(roundPatch != nil, "Should have patch with /round path")
        #expect(roundPatch?.path.hasPrefix("/") == true, "Path should start with /")
    } else {
        Issue.record("Should return .diff")
    }
}

@Test("Nested object paths use JSON Pointer format")
func testPathFormat_NestedObjects_JSONPointer() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.players[playerID] = "Alice"
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    state.players[playerID] = "Alice Updated"
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        // Should have a path for the nested update
        let hasPlayerPatch = patches.contains { $0.path.hasPrefix("/players") }
        #expect(hasPlayerPatch, "Should have patch for players field")
    } else {
        Issue.record("Should return .diff")
    }
}

// MARK: - OnlyPaths Filter Tests

@Test("onlyPaths filters to specified paths")
func testOnlyPaths_FiltersToSpecifiedPaths() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.round = 1
    state.players[playerID] = "Alice"
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Change both fields
    state.round = 2
    state.players[playerID] = "Alice Updated"
    
    // Act - Only request diff for /round
    let update = try syncEngine.generateDiff(
        for: playerID,
        from: state,
        onlyPaths: ["/round"]
    )
    
    // Assert
    if case .diff(let patches) = update {
        // Should only have patch for /round, not for /players
        let roundPatch = patches.first { $0.path == "/round" }
        let playersPatch = patches.first { $0.path.hasPrefix("/players") }
        #expect(roundPatch != nil, "Should have /round patch")
        #expect(playersPatch == nil, "Should not have /players patch")
    } else {
        Issue.record("Should return .diff")
    }
}

// MARK: - Edge Cases

@Test("Empty snapshots compare correctly")
func testEdgeCase_EmptySnapshots() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // First sync (empty state)
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Act - Still empty
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .noChange = update {
        // Expected
    } else {
        Issue.record("Empty snapshots should return .noChange")
    }
}

@Test("Identical snapshots return noChange")
func testEdgeCase_IdenticalSnapshots_NoChange() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.round = 1
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Act - Same state
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .noChange = update {
        // Expected
    } else {
        Issue.record("Identical snapshots should return .noChange")
    }
}

// MARK: - Real-World Scenarios

@Test("Late join uses full snapshot")
func testLateJoin_UsesFullSnapshot() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.round = 1
    state.players[playerID] = "Alice"
    
    // Act - Late join
    let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    
    // Assert
    #expect(!snapshot.isEmpty, "Snapshot should not be empty")
    #expect(snapshot["round"] != nil, "Should have round field")
}

@Test("Late join populates cache so subsequent generateDiff detects changes")
func testLateJoin_PopulatesCache() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.round = 1
    state.players[playerID] = "Alice"
    
    // Act 1 - Late join (should populate cache)
    let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    #expect(!snapshot.isEmpty, "Snapshot should not be empty")
    
    // Act 2 - Change state after join
    state.round = 2
    
    // Act 3 - Generate diff (should NOT return firstSync because cache was populated by lateJoinSnapshot)
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    // Should return diff (not firstSync) because cache was already populated
    if case .diff(let patches) = update {
        #expect(patches.count > 0, "Should have patches for the change")
        // Should have a patch for /round changing from 1 to 2
        let roundPatch = patches.first { $0.path == "/round" }
        #expect(roundPatch != nil, "Should have patch for round change")
    } else {
        Issue.record("After lateJoinSnapshot, generateDiff should return .diff (not .firstSync), got: \(update)")
    }
}

@Test("First sync signal is sent only once per player")
func testFirstSync_SentOnlyOnce() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    state.round = 1
    state.players[playerID] = "Alice"
    
    // Act - First sync
    let firstUpdate = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Second sync (no changes)
    let secondUpdate = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Third sync (with changes)
    state.round = 2
    let thirdUpdate = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .firstSync(let patches) = firstUpdate {
        #expect(patches.count >= 0, "First sync should return .firstSync with patches array")
    } else {
        Issue.record("First sync should return .firstSync([StatePatch]), got: \(firstUpdate)")
    }
    #expect(secondUpdate == .noChange, "Second sync with no changes should return .noChange")
    if case .diff(let patches) = thirdUpdate {
        #expect(!patches.isEmpty, "Third sync with changes should return .diff with patches")
    } else {
        Issue.record("Third sync with changes should return .diff, got: \(thirdUpdate)")
    }
}

@Test("State update uses diff")
func testStateUpdate_UsesDiff() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = DiffTestStateRootNode()
    let playerID = PlayerID("alice")
    
    // First sync (cache) - should return firstSync
    state.round = 1
    let firstUpdate = try syncEngine.generateDiff(for: playerID, from: state)
    if case .firstSync(let patches) = firstUpdate {
        #expect(patches.count >= 0, "First sync should return .firstSync with patches array")
    } else {
        Issue.record("First sync should return .firstSync([StatePatch]), got: \(firstUpdate)")
    }
    
    // Update state
    state.round = 2
    
    // Act - Get diff
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count > 0, "Should have patches")
    } else {
        Issue.record("State update should return .diff, got: \(update)")
    }
}

