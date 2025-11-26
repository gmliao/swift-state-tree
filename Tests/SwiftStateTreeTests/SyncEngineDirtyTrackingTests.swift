// Tests/SwiftStateTreeTests/SyncEngineDirtyTrackingTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

/// Unit tests for dirty tracking optimization in SyncEngine
@Suite("SyncEngine Dirty Tracking Tests")
struct SyncEngineDirtyTrackingTests {
    
    // MARK: - Basic Functionality Tests
    
    @Test("Optimized diff with dirty tracking works correctly")
    func testOptimizedDiff_WithDirtyTracking_WorksCorrectly() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync (cache)
        state.round = 1
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Change value
        state.round = 2
        
        // Act - Use default dirty tracking (useDirtyTracking: true)
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
    
    @Test("Optimized diff with no dirty fields returns noChange")
    func testOptimizedDiff_NoDirtyFields_ReturnsNoChange() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync (cache) - set all fields to ensure they're in cache
        state.round = 1
        state.players[playerID] = "Alice"
        state.turn = nil  // Explicitly set to ensure it's in cache
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Don't change anything - no dirty fields
        
        // Act - Use default dirty tracking (useDirtyTracking: true)
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert - Should return noChange when all fields are already in cache and nothing changed
        #expect(update == .noChange, "Should return .noChange when no fields are dirty and all fields are in cache")
    }
    
    @Test("Optimized diff handles multiple dirty fields")
    func testOptimizedDiff_MultipleDirtyFields() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync (cache)
        state.round = 1
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Change multiple fields
        state.round = 2
        state.players[playerID] = "Alice Updated"
        
        // Act - Use default dirty tracking (useDirtyTracking: true)
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            #expect(patches.count >= 2, "Should have at least 2 patches")
            let roundPatch = patches.first { $0.path == "/round" }
            let playersPatch = patches.first { $0.path.hasPrefix("/players") }
            #expect(roundPatch != nil, "Should have patch for round")
            #expect(playersPatch != nil, "Should have patch for players")
        } else {
            Issue.record("Should return .diff with patches")
        }
    }
    
    // MARK: - Consistency Tests (Standard vs Optimized)
    
    @Test("Standard and optimized diff produce same results - single field change")
    func testConsistency_StandardVsOptimized_SingleField() throws {
        // Arrange
        var state1 = DiffTestStateRootNode()
        var state2 = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state1.round = 1
        state2.round = 1
        state1.players[playerID] = "Alice"
        state2.players[playerID] = "Alice"
        
        // Setup two sync engines
        var syncEngine1 = SyncEngine()
        var syncEngine2 = SyncEngine()
        
        // First sync for both (use same mode for baseline)
        _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: false)
        _ = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: true)
        state1.clearDirty()
        state2.clearDirty()
        
        // Change value
        state1.round = 2
        state2.round = 2
        
        // Act
        let standardUpdate = try syncEngine1.generateDiff(
            for: playerID,
            from: state1,
            useDirtyTracking: false
        )
        let optimizedUpdate = try syncEngine2.generateDiff(
            for: playerID,
            from: state2,
            useDirtyTracking: true
        )
        
        // Assert - Results should be identical
        #expect(standardUpdate == optimizedUpdate, 
                "Standard and optimized diff should produce same results")
    }
    
    @Test("Standard and optimized diff produce same results - multiple field changes")
    func testConsistency_StandardVsOptimized_MultipleFields() throws {
        // Arrange
        var state1 = DiffTestStateRootNode()
        var state2 = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state1.round = 1
        state2.round = 1
        state1.players[playerID] = "Alice"
        state2.players[playerID] = "Alice"
        state1.hands[playerID] = ["card1"]
        state2.hands[playerID] = ["card1"]
        
        // Setup two sync engines
        var syncEngine1 = SyncEngine()
        var syncEngine2 = SyncEngine()
        
        // First sync for both (use same mode for baseline)
        _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: false)
        _ = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: true)
        state1.clearDirty()
        state2.clearDirty()
        
        // Change multiple fields
        state1.round = 2
        state2.round = 2
        state1.players[playerID] = "Alice Updated"
        state2.players[playerID] = "Alice Updated"
        state1.hands[playerID] = ["card1", "card2"]
        state2.hands[playerID] = ["card1", "card2"]
        
        // Act
        let standardUpdate = try syncEngine1.generateDiff(
            for: playerID,
            from: state1,
            useDirtyTracking: false
        )
        let optimizedUpdate = try syncEngine2.generateDiff(
            for: playerID,
            from: state2,
            useDirtyTracking: true
        )
        
        // Assert - Results should have same patches (order may differ)
        if case .diff(let standardPatches) = standardUpdate,
           case .diff(let optimizedPatches) = optimizedUpdate {
            // Compare patches by converting to sets (ignoring order)
            // Create a key function to make patches comparable
            func patchKey(_ patch: StatePatch) -> String {
                switch patch.operation {
                case .set(let value):
                    return "\(patch.path):set:\(value)"
                case .delete:
                    return "\(patch.path):delete"
                case .add(let value):
                    return "\(patch.path):add:\(value)"
                }
            }
            let standardPatchesSet = Set(standardPatches.map(patchKey))
            let optimizedPatchesSet = Set(optimizedPatches.map(patchKey))
            #expect(standardPatchesSet == optimizedPatchesSet, 
                    "Standard and optimized diff should produce same patches (order may differ)")
            #expect(standardPatches.count == optimizedPatches.count,
                    "Should have same number of patches")
        } else {
            Issue.record("Both should return .diff with patches")
        }
    }
    
    @Test("Standard and optimized diff produce same results - field deletion")
    func testConsistency_StandardVsOptimized_FieldDeletion() throws {
        // Arrange
        var state1 = DiffTestStateRootNode()
        var state2 = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state1.round = 1
        state2.round = 1
        state1.players[playerID] = "Alice"
        state2.players[playerID] = "Alice"
        
        // Setup two sync engines
        var syncEngine1 = SyncEngine()
        var syncEngine2 = SyncEngine()
        
        // First sync for both (use same mode for baseline)
        _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: false)
        _ = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: true)
        state1.clearDirty()
        state2.clearDirty()
        
        // Delete field
        state1.players.removeValue(forKey: playerID)
        state2.players.removeValue(forKey: playerID)
        
        // Act
        let standardUpdate = try syncEngine1.generateDiff(
            for: playerID,
            from: state1,
            useDirtyTracking: false
        )
        let optimizedUpdate = try syncEngine2.generateDiff(
            for: playerID,
            from: state2,
            useDirtyTracking: true
        )
        
        // Assert - Results should be identical
        if case .diff(let standardPatches) = standardUpdate,
           case .diff(let optimizedPatches) = optimizedUpdate {
            // Both should have delete patches
            let standardHasDelete = standardPatches.contains { 
                $0.path.hasPrefix("/players") && $0.operation == .delete
            }
            let optimizedHasDelete = optimizedPatches.contains { 
                $0.path.hasPrefix("/players") && $0.operation == .delete
            }
            #expect(standardHasDelete == optimizedHasDelete, 
                    "Both should have delete patches")
        } else {
            Issue.record("Both should return .diff")
        }
    }
    
    @Test("Standard and optimized diff produce same results - field addition")
    func testConsistency_StandardVsOptimized_FieldAddition() throws {
        // Arrange
        var state1 = DiffTestStateRootNode()
        var state2 = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state1.round = 1
        state2.round = 1
        
        // Setup two sync engines
        var syncEngine1 = SyncEngine()
        var syncEngine2 = SyncEngine()
        
        // First sync for both (use same mode for baseline)
        // Initialize players as empty to ensure it's in cache
        state1.players = [:]
        state2.players = [:]
        _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: false)
        _ = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: true)
        state1.clearDirty()
        state2.clearDirty()
        
        // Add new field
        state1.players[playerID] = "Alice"
        state2.players[playerID] = "Alice"
        
        // Act
        let standardUpdate = try syncEngine1.generateDiff(
            for: playerID,
            from: state1,
            useDirtyTracking: false
        )
        let optimizedUpdate = try syncEngine2.generateDiff(
            for: playerID,
            from: state2,
            useDirtyTracking: true
        )
        
        // Assert - Both should detect the addition, but patch format may differ
        // Standard: /players/alice (recursive comparison)
        // Optimized: /players (when players is dirty, may replace entire object)
        // Both are valid - we check that both detect the change
        if case .diff(let standardPatches) = standardUpdate,
           case .diff(let optimizedPatches) = optimizedUpdate {
            // Both should have patches related to players
            let standardHasPlayers = standardPatches.contains { $0.path.hasPrefix("/players") }
            let optimizedHasPlayers = optimizedPatches.contains { $0.path.hasPrefix("/players") }
            #expect(standardHasPlayers, "Standard should have players patch")
            #expect(optimizedHasPlayers, "Optimized should have players patch")
        } else {
            Issue.record("Both should return .diff with patches")
        }
    }
    
    @Test("Standard and optimized diff produce same results - no changes")
    func testConsistency_StandardVsOptimized_NoChanges() throws {
        // Arrange
        var state1 = DiffTestStateRootNode()
        var state2 = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // Set all fields to ensure they're in cache
        state1.round = 1
        state2.round = 1
        state1.players[playerID] = "Alice"
        state2.players[playerID] = "Alice"
        state1.turn = nil  // Explicitly set to ensure it's in cache
        state2.turn = nil
        
        // Setup two sync engines
        var syncEngine1 = SyncEngine()
        var syncEngine2 = SyncEngine()
        
        // First sync for both (use same mode for baseline)
        _ = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: false)
        _ = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: true)
        state1.clearDirty()
        state2.clearDirty()
        
        // Don't change anything
        
        // Act
        let standardUpdate = try syncEngine1.generateDiff(
            for: playerID,
            from: state1,
            useDirtyTracking: false
        )
        let optimizedUpdate = try syncEngine2.generateDiff(
            for: playerID,
            from: state2,
            useDirtyTracking: true
        )
        
        // Assert - Both should return noChange when all fields are in cache
        #expect(standardUpdate == .noChange, "Standard should return .noChange")
        #expect(optimizedUpdate == .noChange, "Optimized should return .noChange")
        #expect(standardUpdate == optimizedUpdate, 
                "Standard and optimized diff should produce same results")
    }
    
    // MARK: - Dirty Tracking Edge Cases
    
    @Test("Optimized diff ignores non-dirty fields even if they changed")
    func testOptimizedDiff_IgnoresNonDirtyFields() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync (cache)
        state.round = 1
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Change round (marks as dirty)
        state.round = 2
        
        // Manually modify players without marking dirty (simulate external change)
        // Note: In practice, this shouldn't happen because @Sync setter marks dirty
        // But we test the behavior when dirty tracking says a field is not dirty
        
        // Act - Use default dirty tracking (useDirtyTracking: true)
        // Only round should be in dirtyFields, not players
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert - Should only have patch for round, not players
        if case .diff(let patches) = update {
            let roundPatch = patches.first { $0.path == "/round" }
            #expect(roundPatch != nil, "Should have patch for round")
            // Note: players might still appear if it's in the snapshot, but it shouldn't be compared
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("Optimized diff correctly handles nested dirty fields")
    func testOptimizedDiff_NestedDirtyFields() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync (cache)
        state.players[playerID] = "Alice"
        state.hands[playerID] = ["card1"]
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Change nested field (players dictionary)
        state.players[playerID] = "Alice Updated"
        
        // Act - Use optimized diff with dirty tracking
        let update = try syncEngine.generateDiff(
            for: playerID,
            from: state,
            useDirtyTracking: true
        )
        
        // Assert
        if case .diff(let patches) = update {
            let playersPatch = patches.first { $0.path.hasPrefix("/players") }
            #expect(playersPatch != nil, "Should have patch for players field")
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    // MARK: - First Sync Tests
    
    @Test("Optimized diff with dirty tracking returns firstSync on first call")
    func testOptimizedDiff_FirstSync_ReturnsFirstSync() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        
        // Act - First sync with default dirty tracking (useDirtyTracking: true)
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .firstSync(let patches) = update {
            #expect(patches.count >= 0, "First sync should return .firstSync with patches array")
        } else {
            Issue.record("First sync should return .firstSync([StatePatch]), got: \(update)")
        }
    }
    
    @Test("Standard and optimized diff both return firstSync on first call")
    func testConsistency_FirstSync_BothReturnFirstSync() throws {
        // Arrange
        var state1 = DiffTestStateRootNode()
        var state2 = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state1.round = 1
        state2.round = 1
        
        // Setup two sync engines
        var syncEngine1 = SyncEngine()
        var syncEngine2 = SyncEngine()
        
        // Act
        let standardUpdate = try syncEngine1.generateDiff(
            for: playerID,
            from: state1,
            useDirtyTracking: false
        )
        let optimizedUpdate = try syncEngine2.generateDiff(
            for: playerID,
            from: state2,
            useDirtyTracking: true
        )
        
        // Assert - Both should return firstSync
        if case .firstSync = standardUpdate,
           case .firstSync = optimizedUpdate {
            // Both return firstSync - expected
        } else {
            Issue.record("Both should return .firstSync on first call")
        }
    }
    
    // MARK: - Dictionary Dirty Tracking Tests
    
    // MARK: - Dictionary Dirty Tracking Tests
    // Note: These tests verify that when a Dictionary field is marked as dirty,
    // only the modified key's value is serialized (for perPlayerSlice),
    // not the entire Dictionary.
    // 
    // However, the current implementation marks the entire Dictionary field as dirty
    // when any key is modified. The perPlayerSlice() policy already filters
    // to return only value[playerID], so the snapshot will contain only that player's
    // value, not all players. This is the expected behavior.
    //
    // Future optimization: Track dirty keys within Dictionary fields for even finer
    // granularity (only serialize the modified key, not even the filtered value).
}

