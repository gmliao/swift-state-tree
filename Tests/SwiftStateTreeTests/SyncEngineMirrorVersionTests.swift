// Tests/SwiftStateTreeTests/SyncEngineMirrorVersionTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

/// Test extractBroadcastSnapshotMirrorVersion with Dictionary types
@Suite("SyncEngine Mirror Version Tests")
struct SyncEngineMirrorVersionTests {
    
    @Test("extractBroadcastSnapshotMirrorVersion handles Dictionary property wrapper correctly")
    func testExtractBroadcastSnapshotMirrorVersion_DictionaryPropertyWrapper() throws {
        // Arrange
        var state = BenchmarkStateRootNode()
        let playerID = PlayerID("player_0")
        
        state.players[playerID] = BenchmarkPlayerState(
            name: "Test Player",
            hpCurrent: 100,
            hpMax: 100
        )
        state.round = 1
        
        let syncEngine = SyncEngine()
        
        // Act - This should not crash with "Unsupported type: SyncPolicy<Dictionary<...>>"
        let snapshot = try syncEngine.extractBroadcastSnapshotMirrorVersion(from: state)
        
        // Assert
        #expect(!snapshot.isEmpty, "Snapshot should not be empty")
        #expect(snapshot["round"] != nil, "Should have round field")
        #expect(snapshot["players"] != nil, "Should have players field")
    }
    
    @Test("extractBroadcastSnapshotMirrorVersion handles nested structures correctly")
    func testExtractBroadcastSnapshotMirrorVersion_NestedStructures() throws {
        // Arrange
        var state = BenchmarkStateRootNode()
        let playerID = PlayerID("player_0")
        
        state.players[playerID] = BenchmarkPlayerState(
            name: "Test Player",
            hpCurrent: 100,
            hpMax: 100
        )
        
        var cards: [BenchmarkCard] = []
        for i in 0..<5 {
            cards.append(BenchmarkCard(id: i, suit: i % 4, rank: i % 13))
        }
        state.hands[playerID] = BenchmarkHandState(
            ownerID: playerID,
            cards: cards
        )
        state.round = 1
        
        let syncEngine = SyncEngine()
        
        // Act - This should not crash
        let snapshot = try syncEngine.extractBroadcastSnapshotMirrorVersion(from: state)
        
        // Assert
        #expect(!snapshot.isEmpty, "Snapshot should not be empty")
        #expect(snapshot["round"] != nil, "Should have round field")
        #expect(snapshot["players"] != nil, "Should have players field")
    }
}

