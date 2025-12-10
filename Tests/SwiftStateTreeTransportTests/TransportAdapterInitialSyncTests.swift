// Tests/SwiftStateTreeTransportTests/TransportAdapterInitialSyncTests.swift
//
// Tests for initial sync behavior when players first connect
// Verifies that new players receive complete snapshot, not patches

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct InitialSyncTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.perPlayerSlice())
    var playerScores: [PlayerID: Int] = [:]
}

// MARK: - Tests

@Test("lateJoinSnapshot returns complete state for new player")
func testLateJoinSnapshotReturnsCompleteState() async throws {
    // Arrange
    var state = InitialSyncTestState()
    state.ticks = 5
    state.players[PlayerID("existing")] = "Existing Player"
    state.playerScores[PlayerID("new")] = 0
    
    var syncEngine = SyncEngine()
    
    // Act: Get snapshot for new player
    let snapshot = try syncEngine.lateJoinSnapshot(for: PlayerID("new"), from: state)
    
    // Assert: Snapshot should contain all visible fields
    #expect(snapshot.values["ticks"] != nil, "Snapshot should contain ticks (broadcast)")
    #expect(snapshot.values["players"] != nil, "Snapshot should contain players (broadcast)")
    #expect(snapshot.values["playerScores"] != nil, "Snapshot should contain playerScores (per-player)")
    #expect(!snapshot.values.isEmpty, "Snapshot should not be empty")
    
    // Verify snapshot can be encoded as JSON (for direct transmission)
    let encoder = JSONEncoder()
    let snapshotData = try encoder.encode(snapshot)
    let jsonString = String(data: snapshotData, encoding: .utf8) ?? ""
    
        // Verify it's NOT a StateUpdate format (should not have "type" field at root level or "patches" field)
        // Note: SnapshotValue now uses "type" + "value" format, so we check for "patches" instead
        #expect(!jsonString.contains("\"patches\""), "Should not be StateUpdate format")
    #expect(!jsonString.contains("\"patches\""), "Should not contain patches")
    #expect(jsonString.contains("\"values\""), "Should contain values field")
}

@Test("lateJoinSnapshot populates cache but first generateDiff still returns firstSync")
func testLateJoinSnapshotPopulatesCache() async throws {
    // Arrange
    var state = InitialSyncTestState()
    state.ticks = 10
    
    var syncEngine = SyncEngine()
    let playerID = PlayerID("test")
    
    // Act: Get lateJoinSnapshot (populates cache but doesn't mark firstSync as received)
    let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    #expect(!snapshot.values.isEmpty, "Snapshot should not be empty")
    
    // Modify state
    state.ticks = 20
    
    // Act: Generate diff (will return firstSync because hasReceivedFirstSync is not set)
    // This is by design: lateJoinSnapshot populates cache but doesn't mark firstSync received
    // The first generateDiff after lateJoinSnapshot will return firstSync with patches
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return firstSync (not diff) because hasReceivedFirstSync is not set
    // This is correct behavior: lateJoinSnapshot doesn't mark firstSync as received
    switch update {
    case .firstSync(let patches):
        // First sync should have patches for the change
        #expect(!patches.isEmpty, "FirstSync should have patches for ticks change")
        let ticksPatch = patches.first { $0.path == "/ticks" }
        #expect(ticksPatch != nil, "Should have patch for ticks")
    case .diff:
        Issue.record("Should return firstSync, not diff, because hasReceivedFirstSync is not set")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
    
    // Act: Generate diff again (should now return diff)
    state.ticks = 30
    let update2 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should now return diff (not firstSync) because firstSync was already sent
    switch update2 {
    case .firstSync:
        Issue.record("Should return diff, not firstSync, because firstSync was already sent")
    case .diff(let patches):
        #expect(!patches.isEmpty, "Diff should have patches for ticks change")
        let ticksPatch = patches.first { $0.path == "/ticks" }
        #expect(ticksPatch != nil, "Should have patch for ticks")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
}

@Test("Initial snapshot format is different from diff format")
func testInitialSnapshotFormatIsDifferentFromDiff() async throws {
    // Arrange
    var state = InitialSyncTestState()
    state.ticks = 10
    state.players[PlayerID("alice")] = "Alice"
    state.playerScores[PlayerID("alice")] = 100
    
    var syncEngine = SyncEngine()
    let playerID = PlayerID("alice")
    
    // Act: Get initial snapshot (lateJoinSnapshot)
    let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    let snapshotData = try JSONEncoder().encode(snapshot)
    let snapshotString = String(data: snapshotData, encoding: .utf8) ?? ""
    
    // Act: Get diff update
    state.ticks = 20
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    let updateData = try JSONEncoder().encode(update)
    let updateString = String(data: updateData, encoding: .utf8) ?? ""
    
    // Assert: Snapshot format should be different from StateUpdate format
    // Note: SnapshotValue now uses "type" + "value" format, so we check for "patches" instead
    #expect(snapshotString.contains("\"values\""), "Snapshot should have 'values' field")
    #expect(!snapshotString.contains("\"patches\""), "Snapshot should NOT have 'patches' field (StateUpdate format)")
    
    // Assert: StateUpdate format should have type and patches
    #expect(updateString.contains("\"type\""), "StateUpdate should have 'type' field")
    #expect(updateString.contains("\"patches\""), "StateUpdate should have 'patches' field")
    #expect(!updateString.contains("\"values\""), "StateUpdate should NOT have 'values' field")
}

@Test("lateJoinSnapshot includes both broadcast and per-player fields")
func testLateJoinSnapshotIncludesAllFields() async throws {
    // Arrange
    var state = InitialSyncTestState()
    state.ticks = 10
    state.players[PlayerID("alice")] = "Alice"
    state.players[PlayerID("bob")] = "Bob"
    state.playerScores[PlayerID("alice")] = 100
    state.playerScores[PlayerID("bob")] = 200
    
    var syncEngine = SyncEngine()
    let aliceID = PlayerID("alice")
    
    // Act: Get snapshot for alice
    let snapshot = try syncEngine.lateJoinSnapshot(for: aliceID, from: state)
    
    // Assert: Should contain broadcast fields
    #expect(snapshot.values["ticks"] != nil, "Should contain ticks")
    #expect(snapshot.values["players"] != nil, "Should contain players")
    
    // Assert: Should contain per-player fields
    #expect(snapshot.values["playerScores"] != nil, "Should contain playerScores")
    
    // Verify snapshot has multiple fields
    #expect(snapshot.values.count >= 3, "Snapshot should contain at least 3 fields")
}
