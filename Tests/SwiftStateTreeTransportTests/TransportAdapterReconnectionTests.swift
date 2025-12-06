// Tests/SwiftStateTreeTransportTests/TransportAdapterReconnectionTests.swift
//
// Tests for reconnection behavior when players disconnect and reconnect
// Verifies that reconnected players don't receive duplicate updates

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct ReconnectionTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var gameTime: Int = 0
}

// MARK: - Tests

@Test("SyncEngine clearCacheForDisconnectedPlayer clears cache correctly")
func testSyncEngineClearCache() async throws {
    // Arrange
    var state = ReconnectionTestState()
    state.ticks = 10
    state.gameTime = 100
    
    var syncEngine = SyncEngine()
    let playerID = PlayerID("alice")
    
    // Act: Get lateJoinSnapshot (populates cache)
    let snapshot1 = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    #expect(!snapshot1.values.isEmpty, "Snapshot should not be empty")
    
    // Modify state
    state.ticks = 20
    
    // Act: Generate diff (should return firstSync because hasReceivedFirstSync is not set)
    let update1 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return firstSync
    switch update1 {
    case .firstSync(let patches):
        #expect(!patches.isEmpty, "Should have patches for ticks change")
    default:
        Issue.record("Should return firstSync after lateJoinSnapshot")
    }
    
    // Act: Generate diff again (should return diff)
    state.ticks = 30
    let update2 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return diff (not firstSync)
    switch update2 {
    case .diff(let patches):
        #expect(!patches.isEmpty, "Should have patches for ticks change")
    default:
        Issue.record("Should return diff after firstSync was sent")
    }
    
    // Act: Clear cache for disconnected player
    syncEngine.clearCacheForDisconnectedPlayer(playerID)
    
    // Modify state again
    state.ticks = 40
    
    // Act: Generate diff after cache clear (should return firstSync again)
    let update3 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return firstSync (not diff) because cache was cleared
    switch update3 {
    case .firstSync(let patches):
        #expect(!patches.isEmpty, "Should have patches for ticks change after cache clear")
    case .diff:
        Issue.record("Should return firstSync after cache clear, not diff")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
}

@Test("After lateJoinSnapshot, markFirstSyncReceived prevents duplicate firstSync")
func testMarkFirstSyncReceivedPreventsDuplicate() async throws {
    // Arrange
    var state = ReconnectionTestState()
    state.ticks = 10
    
    var syncEngine = SyncEngine()
    let playerID = PlayerID("alice")
    
    // Act: Get lateJoinSnapshot (populates cache but doesn't mark firstSync)
    let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    #expect(!snapshot.values.isEmpty, "Snapshot should not be empty")
    
    // Act: Mark firstSync as received (simulating what TransportAdapter does after sending snapshot)
    syncEngine.markFirstSyncReceived(for: playerID)
    
    // State doesn't change
    // Act: Generate diff (should return noChange, not firstSync)
    let update1 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return noChange (not firstSync) because:
    // 1. Cache is populated (no changes)
    // 2. hasReceivedFirstSync is set (so won't return firstSync even if there were changes)
    switch update1 {
    case .noChange:
        // Expected: no changes, and firstSync already marked as received
        break
    case .firstSync:
        Issue.record("Should return noChange, not firstSync, because firstSync was already marked as received")
    case .diff:
        Issue.record("Should return noChange, not diff, because state didn't change")
    }
    
    // Now state changes
    state.ticks = 20
    
    // Act: Generate diff (should return diff, not firstSync)
    let update2 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return diff (not firstSync) because hasReceivedFirstSync is set
    switch update2 {
    case .diff(let patches):
        #expect(!patches.isEmpty, "Should have patches for ticks change")
    case .firstSync:
        Issue.record("Should return diff, not firstSync, because firstSync was already marked as received")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
}

@Test("Reconnection scenario: lateJoinSnapshot then generateDiff should work correctly")
func testReconnectionScenario() async throws {
    // Arrange
    var state = ReconnectionTestState()
    state.ticks = 10
    
    var syncEngine = SyncEngine()
    let playerID = PlayerID("alice")
    
    // Simulate first connection: lateJoinSnapshot
    let snapshot = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    #expect(!snapshot.values.isEmpty, "Snapshot should not be empty")
    
    // State changes while player is connected
    state.ticks = 20
    let update1 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return firstSync (because hasReceivedFirstSync is not set)
    switch update1 {
    case .firstSync(let patches):
        #expect(!patches.isEmpty, "Should have patches")
    default:
        Issue.record("Should return firstSync")
    }
    
    // More state changes
    state.ticks = 30
    let update2 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return diff
    switch update2 {
    case .diff(let patches):
        #expect(!patches.isEmpty, "Should have patches")
    default:
        Issue.record("Should return diff")
    }
    
    // Simulate disconnect: clear cache
    syncEngine.clearCacheForDisconnectedPlayer(playerID)
    
    // Simulate reconnection: lateJoinSnapshot again
    let snapshot2 = try syncEngine.lateJoinSnapshot(for: playerID, from: state)
    #expect(!snapshot2.values.isEmpty, "Snapshot should not be empty")
    
    // State changes after reconnection
    state.ticks = 40
    
    // Act: Generate diff after reconnection
    let update3 = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert: Should return firstSync (not diff) because cache was cleared and hasReceivedFirstSync was reset
    switch update3 {
    case .firstSync(let patches):
        #expect(!patches.isEmpty, "Should have patches after reconnection")
    case .diff:
        Issue.record("Should return firstSync after reconnection, not diff")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
}

@Test("First player connects, leaves, then second player connects")
func testFirstPlayerLeavesThenSecondConnects() async throws {
    // Arrange
    var state = ReconnectionTestState()
    state.ticks = 10
    
    var syncEngine = SyncEngine()
    let aliceID = PlayerID("alice")
    let bobID = PlayerID("bob")
    
    // Act: Alice connects (first player)
    let aliceSnapshot = try syncEngine.lateJoinSnapshot(for: aliceID, from: state)
    #expect(!aliceSnapshot.values.isEmpty, "Alice snapshot should not be empty")
    // Mark firstSync as received (simulating TransportAdapter behavior)
    syncEngine.markFirstSyncReceived(for: aliceID)
    
    // State changes while Alice is connected
    state.ticks = 20
    let aliceUpdate = try syncEngine.generateDiff(for: aliceID, from: state)
    
    // Assert: Should return diff (not firstSync) because firstSync was already marked
    switch aliceUpdate {
    case .diff(let patches):
        #expect(!patches.isEmpty, "Should have patches for Alice")
    case .firstSync:
        Issue.record("Should return diff for Alice, not firstSync, because firstSync was already marked")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
    
    // Act: Alice disconnects
    syncEngine.clearCacheForDisconnectedPlayer(aliceID)
    
    // More state changes after Alice leaves
    state.ticks = 30
    
    // Act: Bob connects (second player, different playerID)
    let bobSnapshot = try syncEngine.lateJoinSnapshot(for: bobID, from: state)
    #expect(!bobSnapshot.values.isEmpty, "Bob snapshot should not be empty")
    // Mark firstSync as received (simulating TransportAdapter behavior)
    syncEngine.markFirstSyncReceived(for: bobID)
    
    // State changes while Bob is connected
    state.ticks = 40
    let bobUpdate = try syncEngine.generateDiff(for: bobID, from: state)
    
    // Assert: Should return diff (not firstSync) because firstSync was already marked for Bob
    switch bobUpdate {
    case .diff(let patches):
        #expect(!patches.isEmpty, "Should have patches for Bob")
    case .firstSync:
        Issue.record("Should return diff for Bob, not firstSync, because firstSync was already marked")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
    
    // Verify: Alice's cache is cleared, Bob's cache is populated
    // If Alice reconnects, she should receive firstSync again
    state.ticks = 50
    let aliceReconnectUpdate = try syncEngine.generateDiff(for: aliceID, from: state)
    
    // Assert: Should return firstSync because Alice's cache was cleared
    switch aliceReconnectUpdate {
    case .firstSync(let patches):
        #expect(!patches.isEmpty, "Should have patches for Alice reconnection")
    case .diff:
        Issue.record("Should return firstSync for Alice reconnection, not diff, because cache was cleared")
    case .noChange:
        Issue.record("Should have changes after modifying ticks")
    }
}

