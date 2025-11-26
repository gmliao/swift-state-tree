// Tests/SwiftStateTreeTests/SyncEngineDirtyTrackingTests_PatchAnalysis.swift
//
// 分析測試：查看實際生成的 patch 和更新內容

import Foundation
import Testing
@testable import SwiftStateTree

/// 分析測試：查看實際生成的 patch
@Suite("Patch Analysis Tests")
struct SyncEngineDirtyTrackingTests_PatchAnalysis {
    
    @Test("Analyze: What's in snapshot for broadcast vs perPlayer dictionary")
    func testAnalyze_SnapshotContent() throws {
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // Setup state
        state.round = 1
        state.players[playerID] = "Alice"
        state.hands[playerID] = ["card1", "card2"]
        
        // Generate snapshots
        let fullSnapshot = try state.snapshot(for: playerID, dirtyFields: nil)
        _ = try state.broadcastSnapshot(dirtyFields: nil)
        
        // Simulate extractPerPlayerSnapshot logic
        let syncFields = state.getSyncFields()
        let perPlayerFieldNames = Set(
            syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }
                .map { $0.name }
        )
        var perPlayerValues: [String: SnapshotValue] = [:]
        for (key, value) in fullSnapshot.values where perPlayerFieldNames.contains(key) {
            perPlayerValues[key] = value
        }
    }
    
    @Test("Analyze: Standard vs Optimized patch format for dictionary field addition")
    func testAnalyze_StandardVsOptimized_PatchFormat() throws {
        // Arrange
        var state1 = DiffTestStateRootNode()
        var state2 = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        state1.round = 1
        state2.round = 1
        
        // Setup two sync engines
        var syncEngine1 = SyncEngine()
        var syncEngine2 = SyncEngine()
        
        // First sync for both - initialize players as empty
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
        
        // Assert - Both should detect the addition
        if case .diff(let standardPatches) = standardUpdate,
           case .diff(let optimizedPatches) = optimizedUpdate {
            let standardHasPlayers = standardPatches.contains { $0.path.hasPrefix("/players") }
            let optimizedHasPlayers = optimizedPatches.contains { $0.path.hasPrefix("/players") }
            #expect(standardHasPlayers, "Standard should have players patch")
            #expect(optimizedHasPlayers, "Optimized should have players patch")
        }
    }
    
    @Test("Analyze: Broadcast dictionary vs perPlayer dictionary")
    func testAnalyze_BroadcastVsPerPlayer() throws {
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // Test broadcast dictionary (players)
        state.round = 1
        state.players = [:]
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        state.players[playerID] = "Alice"
        let update2 = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Test perPlayer dictionary (hands) - Standard
        var syncEngine2 = SyncEngine()
        var state2 = DiffTestStateRootNode()
        state2.round = 1
        state2.hands = [:]
        _ = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: false)
        state2.clearDirty()
        
        state2.hands[playerID] = ["card1"]
        let update4 = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: false)
        
        // Test perPlayer dictionary (hands) - Optimized
        var syncEngine3 = SyncEngine()
        var state3 = DiffTestStateRootNode()
        state3.round = 1
        state3.hands = [:]
        _ = try syncEngine3.generateDiff(for: playerID, from: state3, useDirtyTracking: true)
        state3.clearDirty()
        
        state3.hands[playerID] = ["card1"]
        let update5 = try syncEngine3.generateDiff(for: playerID, from: state3, useDirtyTracking: true)
        
        // Verify patches were generated
        #expect(update2 != .firstSync([]), "Broadcast dictionary should generate update")
        #expect(update4 != .firstSync([]), "PerPlayer dictionary (standard) should generate update")
        #expect(update5 != .firstSync([]), "PerPlayer dictionary (optimized) should generate update")
    }
}
