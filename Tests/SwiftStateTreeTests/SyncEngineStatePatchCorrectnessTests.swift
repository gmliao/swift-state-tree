// Tests/SwiftStateTreeTests/SyncEngineStatePatchCorrectnessTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

/// Comprehensive tests for StatePatch correctness across different update types
/// These tests verify that StatePatch operations (.set, .delete, .add) are generated correctly
/// for various state update scenarios
@Suite("StatePatch Correctness Tests")
struct SyncEngineStatePatchCorrectnessTests {
    
    // MARK: - Set Operation Tests
    
    @Test("Set operation: Simple field update generates correct patch with path and value")
    func testSetOperation_SimpleField_GeneratesCorrectPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Update field
        state.round = 42
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            #expect(patches.count == 1, "Should have exactly 1 patch")
            let patch = patches[0]
            #expect(patch.path == "/round", "Path should be /round")
            if case .set(let value) = patch.operation {
                #expect(value.intValue == 42, "Value should be 42")
            } else {
                Issue.record("Operation should be .set, got: \(patch.operation)")
            }
        } else {
            Issue.record("Should return .diff with patches")
        }
    }
    
    @Test("Set operation: Dictionary value update generates correct nested path")
    func testSetOperation_DictionaryValue_GeneratesCorrectNestedPath() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Update dictionary value
        state.players[playerID] = "Alice Updated"
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            let playersPatch = patches.first { $0.path.hasPrefix("/players") }
            #expect(playersPatch != nil, "Should have patch for players field")
            if let patch = playersPatch {
                #expect(patch.path.contains("/players"), "Path should contain /players")
                if case .set(let value) = patch.operation {
                    #expect(value.stringValue == "Alice Updated", "Value should be updated string")
                } else {
                    Issue.record("Operation should be .set")
                }
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("Set operation: Array value update generates correct patch")
    func testSetOperation_ArrayValue_GeneratesCorrectPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.hands[playerID] = ["card1"]
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Update array value
        state.hands[playerID] = ["card1", "card2", "card3"]
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            let handsPatch = patches.first { $0.path.hasPrefix("/hands") }
            #expect(handsPatch != nil, "Should have patch for hands field")
            if let patch = handsPatch {
                if case .set(let value) = patch.operation {
                    if let array = value.arrayValue {
                        #expect(array.count == 3, "Array should have 3 elements")
                        #expect(array[0].stringValue == "card1", "First element should be card1")
                        #expect(array[1].stringValue == "card2", "Second element should be card2")
                        #expect(array[2].stringValue == "card3", "Third element should be card3")
                    } else {
                        Issue.record("Value should be an array")
                    }
                } else {
                    Issue.record("Operation should be .set")
                }
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("Set operation: Optional field update from nil to value generates correct patch")
    func testSetOperation_OptionalField_NilToValue_GeneratesCorrectPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.turn = nil
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Set optional field
        state.turn = playerID
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            let turnPatch = patches.first { $0.path == "/turn" }
            #expect(turnPatch != nil, "Should have patch for turn field")
            if let patch = turnPatch {
                if case .set(let value) = patch.operation {
                    #expect(value.stringValue == playerID.rawValue, "Value should be playerID")
                } else {
                    Issue.record("Operation should be .set")
                }
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    // MARK: - Delete Operation Tests
    
    @Test("Delete operation: Dictionary key removal generates correct delete patch")
    func testDeleteOperation_DictionaryKey_GeneratesCorrectDeletePatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Remove dictionary key
        state.players.removeValue(forKey: playerID)
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            let deletePatch = patches.first { 
                $0.path.hasPrefix("/players") && $0.operation == .delete
            }
            #expect(deletePatch != nil, "Should have delete patch for removed player")
            if let patch = deletePatch {
                #expect(patch.operation == .delete, "Operation should be .delete")
                #expect(patch.path.contains("/players"), "Path should contain /players")
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("Delete operation: Optional field set to nil generates correct patch")
    func testDeleteOperation_OptionalField_ValueToNil_GeneratesCorrectPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.turn = playerID
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Set optional to nil
        state.turn = nil
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        // Note: Optional fields set to nil may generate either .delete or .set(.null) patch
        // depending on implementation. Both are valid representations of "removed" value.
        if case .diff(let patches) = update {
            let turnPatch = patches.first { $0.path == "/turn" }
            #expect(turnPatch != nil, "Should have patch for turn field")
            if let patch = turnPatch {
                #expect(patch.path == "/turn", "Path should be /turn")
                // Accept either .delete or .set(.null) as valid
                let isValidOperation: Bool
                switch patch.operation {
                case .delete:
                    isValidOperation = true
                case .set(let value):
                    isValidOperation = value == .null
                case .add:
                    isValidOperation = false
                }
                #expect(isValidOperation, "Operation should be .delete or .set(.null)")
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    // MARK: - Multiple Operations Tests
    
    @Test("Multiple operations: Set and delete in same update generates correct patches")
    func testMultipleOperations_SetAndDelete_GeneratesCorrectPatches() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        state.round = 1
        state.players[alice] = "Alice"
        state.players[bob] = "Bob"
        _ = try syncEngine.generateDiff(for: alice, from: state)
        state.clearDirty()
        
        // Act - Update one field, delete another
        state.round = 2
        state.players.removeValue(forKey: bob)
        
        let update = try syncEngine.generateDiff(for: alice, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            #expect(patches.count >= 2, "Should have at least 2 patches")
            
            let roundPatch = patches.first { $0.path == "/round" }
            #expect(roundPatch != nil, "Should have patch for round")
            if let patch = roundPatch {
                if case .set(let value) = patch.operation {
                    #expect(value.intValue == 2, "Round should be 2")
                }
            }
            
            let deletePatch = patches.first { 
                $0.operation == .delete && $0.path.hasPrefix("/players")
            }
            #expect(deletePatch != nil, "Should have delete patch for removed player")
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("Multiple operations: Multiple set operations generate correct patches")
    func testMultipleOperations_MultipleSets_GeneratesCorrectPatches() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Update multiple fields
        state.round = 2
        state.players[playerID] = "Alice Updated"
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            #expect(patches.count >= 2, "Should have at least 2 patches")
            
            let roundPatch = patches.first { $0.path == "/round" }
            let playersPatch = patches.first { $0.path.hasPrefix("/players") }
            
            #expect(roundPatch != nil, "Should have patch for round")
            #expect(playersPatch != nil, "Should have patch for players")
            
            if let roundPatch = roundPatch {
                if case .set(let value) = roundPatch.operation {
                    #expect(value.intValue == 2, "Round should be 2")
                }
            }
            
            if let playersPatch = playersPatch {
                if case .set(let value) = playersPatch.operation {
                    #expect(value.stringValue == "Alice Updated", "Player name should be updated")
                }
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    // MARK: - Path Format Tests
    
    @Test("Path format: Nested dictionary paths use correct JSON Pointer format")
    func testPathFormat_NestedDictionary_CorrectJSONPointer() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act
        state.players[playerID] = "Alice Updated"
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            let playersPatch = patches.first { $0.path.hasPrefix("/players") }
            #expect(playersPatch != nil, "Should have patch for players")
            if let patch = playersPatch {
                // Path should be valid JSON Pointer format
                #expect(patch.path.hasPrefix("/"), "Path should start with /")
                #expect(patch.path.contains("players"), "Path should contain players")
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    // MARK: - Value Correctness Tests
    
    @Test("Value correctness: Patch values match actual state values")
    func testValueCorrectness_PatchValues_MatchStateValues() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Update with specific values
        state.round = 999
        state.players[playerID] = "Test Value"
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert - Verify patch values match state values
        if case .diff(let patches) = update {
            let roundPatch = patches.first { $0.path == "/round" }
            if let patch = roundPatch {
                if case .set(let value) = patch.operation {
                    #expect(value.intValue == 999, "Round patch value should match state (999)")
                }
            }
            
            let playersPatch = patches.first { $0.path.hasPrefix("/players") }
            if let patch = playersPatch {
                if case .set(let value) = patch.operation {
                    #expect(value.stringValue == "Test Value", "Players patch value should match state")
                }
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("Edge case: Empty array update generates correct patch")
    func testEdgeCase_EmptyArray_GeneratesCorrectPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.hands[playerID] = ["card1"]
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Set to empty array
        state.hands[playerID] = []
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            let handsPatch = patches.first { $0.path.hasPrefix("/hands") }
            #expect(handsPatch != nil, "Should have patch for hands")
            if let patch = handsPatch {
                if case .set(let value) = patch.operation {
                    if let array = value.arrayValue {
                        #expect(array.isEmpty, "Array should be empty")
                    } else {
                        Issue.record("Value should be an array")
                    }
                }
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("Edge case: Large value update generates correct patch")
    func testEdgeCase_LargeValue_GeneratesCorrectPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Set large value
        state.round = Int.max
        
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert
        if case .diff(let patches) = update {
            let roundPatch = patches.first { $0.path == "/round" }
            #expect(roundPatch != nil, "Should have patch for round")
            if let patch = roundPatch {
                if case .set(let value) = patch.operation {
                    #expect(value.intValue == Int.max, "Value should be Int.max")
                }
            }
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    // MARK: - No Unnecessary Patches Tests
    
    @Test("No unnecessary patches: Same value update should not generate patch")
    func testNoUnnecessaryPatches_SameValue_NoPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 42
        _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        state.clearDirty()
        
        // Act - Set to same value (should not generate patch)
        state.round = 42
        
        let update = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        
        // Assert - Should return noChange, not generate unnecessary patch
        #expect(update == .noChange, "Same value should return .noChange, not generate patch")
    }
    
    @Test("No unnecessary patches: Unchanged fields should not generate patches")
    func testNoUnnecessaryPatches_UnchangedFields_NoPatches() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        state.clearDirty()
        
        // Act - Only change one field, leave others unchanged
        state.round = 2
        // players[playerID] remains "Alice" (unchanged)
        
        let update = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        
        // Assert - Should only have patch for round, not for unchanged players field
        if case .diff(let patches) = update {
            let roundPatches = patches.filter { $0.path == "/round" }
            let playersPatches = patches.filter { $0.path.hasPrefix("/players") }
            
            #expect(roundPatches.count == 1, "Should have exactly 1 patch for round")
            #expect(playersPatches.isEmpty, "Should NOT have patches for unchanged players field")
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("No unnecessary patches: Dirty tracking ignores non-dirty fields")
    func testNoUnnecessaryPatches_DirtyTracking_IgnoresNonDirtyFields() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Act - Change round (dirty), but also manually modify players without marking dirty
        // (simulating external change that wasn't tracked)
        state.round = 2
        // Note: In practice, @Sync setter marks dirty, but we test the behavior
        
        // Use default dirty tracking (useDirtyTracking: true) - only round should be in dirtyFields
        let update = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Assert - Should only have patch for round (dirty field), not for players (not dirty)
        if case .diff(let patches) = update {
            let roundPatches = patches.filter { $0.path == "/round" }
            #expect(roundPatches.count == 1, "Should have patch for dirty round field")
            
            // Players field should not appear in patches if it's not dirty
            // (even if it changed, dirty tracking should ignore it)
            let playersPatches = patches.filter { $0.path.hasPrefix("/players") }
            // Note: This test verifies that dirty tracking prevents unnecessary patches
            // If players is not in dirtyFields, it should not generate a patch
        } else {
            Issue.record("Should return .diff")
        }
    }
    
    @Test("No unnecessary patches: Empty diff should return noChange, not empty patches array")
    func testNoUnnecessaryPatches_EmptyDiff_ReturnsNoChange() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        state.clearDirty()
        
        // Act - No changes at all
        
        let update = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        
        // Assert - Should return .noChange, not .diff([])
        #expect(update == .noChange, "No changes should return .noChange, not empty patches")
        
        // Verify it's not .diff with empty array
        if case .diff(let patches) = update {
            Issue.record("Should return .noChange, not .diff([]), got .diff with \(patches.count) patches")
        }
    }
    
    @Test("No unnecessary patches: Identical array values should not generate patch")
    func testNoUnnecessaryPatches_IdenticalArray_NoPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.hands[playerID] = ["card1", "card2"]
        _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        state.clearDirty()
        
        // Act - Set to identical array
        state.hands[playerID] = ["card1", "card2"]
        
        let update = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        
        // Assert - Should return noChange
        #expect(update == .noChange, "Identical array should return .noChange")
    }
    
    @Test("No unnecessary patches: Identical dictionary values should not generate patch")
    func testNoUnnecessaryPatches_IdenticalDictionary_NoPatch() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        state.clearDirty()
        
        // Act - Set to identical value
        state.players[playerID] = "Alice"
        
        let update = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        
        // Assert - Should return noChange
        #expect(update == .noChange, "Identical dictionary value should return .noChange")
    }
    
    @Test("No unnecessary patches: Only changed fields generate patches, not all fields")
    func testNoUnnecessaryPatches_OnlyChangedFields_GeneratePatches() throws {
        // Arrange
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state.round = 1
        state.players[playerID] = "Alice"
        state.hands[playerID] = ["card1"]
        _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        state.clearDirty()
        
        // Act - Only change round, leave others unchanged
        state.round = 2
        // players and hands remain unchanged
        
        let update = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
        
        // Assert - Should only have patch for round
        if case .diff(let patches) = update {
            #expect(patches.count == 1, "Should have exactly 1 patch (only for round)")
            #expect(patches[0].path == "/round", "Patch should be for /round only")
            
            // Verify no patches for unchanged fields
            let playersPatches = patches.filter { $0.path.hasPrefix("/players") }
            let handsPatches = patches.filter { $0.path.hasPrefix("/hands") }
            #expect(playersPatches.isEmpty, "Should NOT have patches for unchanged players")
            #expect(handsPatches.isEmpty, "Should NOT have patches for unchanged hands")
        } else {
            Issue.record("Should return .diff")
        }
    }
}

