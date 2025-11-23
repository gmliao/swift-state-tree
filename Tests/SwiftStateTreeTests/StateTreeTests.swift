// Tests/SwiftStateTreeTests/StateTreeTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test StateTree Examples

/// Test StateTree with various sync policies
@StateTreeBuilder
struct TestGameStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.serverOnly)
    var hiddenData: Int = 0
    
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: [String]] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

/// Test StateTree with all fields marked with @Sync
@StateTreeBuilder
struct CompleteStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var publicData: String = "public"
    
    @Sync(.serverOnly)
    var privateData: Int = 42
}

/// Test StateTree with @Internal fields
@StateTreeBuilder
struct StateTreeWithInternal: StateTreeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Internal
    var lastProcessedTimestamp: Date = Date()
    
    @Internal
    var cache: [String: String] = [:]
    
    // Computed property: should be automatically skipped
    var totalPlayers: Int {
        players.count
    }
}

/// Test StateTree with no fields (edge case)
@StateTreeBuilder
struct EmptyStateTree: StateTreeProtocol {
    // No fields
}

// MARK: - StateTree Protocol Tests

// MARK: - Protocol Conformance Tests

@Test("StateTree types can conform to StateTreeProtocol")
func testStateTreeProtocolConformance() {
    // Test that types can conform to StateTreeProtocol
    let gameState = TestGameStateTree()
    let _: StateTreeProtocol = gameState
    
    let emptyState = EmptyStateTree()
    let _: StateTreeProtocol = emptyState
    
    // If we can assign to StateTreeProtocol, conformance is verified
    #expect(true, "Types conform to StateTreeProtocol")
}

@Test("StateTree types are Sendable")
func testStateTreeIsSendable() {
    // Test that StateTree types are Sendable
    let gameState = TestGameStateTree()
    
    // This should compile without errors, indicating Sendable conformance
    let _: any Sendable = gameState
}

// MARK: - getSyncFields Tests

@Test("getSyncFields returns all sync fields")
func testGetSyncFields_ReturnsAllSyncFields() {
    // Arrange
    var gameState = TestGameStateTree()
    gameState.players[PlayerID("alice")] = "Alice"
    gameState.hiddenData = 100
    gameState.round = 1
    
    // Act
    let fields = gameState.getSyncFields()
    
    // Assert
    #expect(fields.count == 4, "Should find 4 @Sync fields")
    
    let fieldNames = Set(fields.map { $0.name })
    #expect(fieldNames.contains("players"), "Should contain 'players' field")
    #expect(fieldNames.contains("hiddenData"), "Should contain 'hiddenData' field")
    #expect(fieldNames.contains("hands"), "Should contain 'hands' field")
    #expect(fieldNames.contains("round"), "Should contain 'round' field")
}

@Test("getSyncFields returns empty array for empty StateTree")
func testGetSyncFields_EmptyStateTree() {
    // Arrange
    let emptyState = EmptyStateTree()
    
    // Act
    let fields = emptyState.getSyncFields()
    
    // Assert
    #expect(fields.count == 0, "Empty StateTree should have no sync fields")
}

@Test("getSyncFields normalizes field names")
func testGetSyncFields_FieldNamesAreNormalized() {
    // Arrange
    let gameState = TestGameStateTree()
    
    // Act
    let fields = gameState.getSyncFields()
    
    // Assert
    // Field names should not have underscore prefix
    for field in fields {
        #expect(!field.name.hasPrefix("_"), "Field name '\(field.name)' should not have underscore prefix")
    }
}

// MARK: - validateSyncFields Tests

@Test("validateSyncFields returns true when all fields have @Sync")
func testValidateSyncFields_AllFieldsHaveSync() {
    // Arrange
    let completeState = CompleteStateTree()
    
    // Act
    let isValid = completeState.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "StateTree with all fields marked with @Sync should validate")
}

@Test("validateSyncFields returns true when fields have @Sync or @Internal")
func testValidateSyncFields_WithInternalFields() {
    // Arrange
    let stateWithInternal = StateTreeWithInternal()
    
    // Act
    let isValid = stateWithInternal.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "StateTree with @Sync and @Internal fields should validate")
}

@Test("validateSyncFields returns true for empty StateTree")
func testValidateSyncFields_EmptyStateTree() {
    // Arrange
    let emptyState = EmptyStateTree()
    
    // Act
    let isValid = emptyState.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "Empty StateTree should validate (no fields to check)")
}

// MARK: - Integration with SyncEngine Tests

@Test("SyncEngine snapshot works with StateTree")
func testSyncEngineSnapshot_WithStateTree() throws {
    // Arrange
    var gameState = TestGameStateTree()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    gameState.players[alice] = "Alice"
    gameState.players[bob] = "Bob"
    gameState.hiddenData = 999  // Should not appear in snapshot
    gameState.hands[alice] = ["card1", "card2"]
    gameState.hands[bob] = ["card3"]
    gameState.round = 5
    
    let syncEngine = SyncEngine()
    
    // Act
    let snapshot = try syncEngine.snapshot(for: alice, from: gameState)
    
    // Assert
    // Broadcast fields should be visible
    #expect(snapshot["players"] != nil, "Broadcast field 'players' should be in snapshot")
    #expect(snapshot["round"] != nil, "Broadcast field 'round' should be in snapshot")
    
    // ServerOnly fields should not be visible
    #expect(snapshot["hiddenData"] == nil, "ServerOnly field 'hiddenData' should not be in snapshot")
    
    // PerPlayer fields: perPlayerDictionaryValue returns value[playerID]
    // So for alice, it returns hands[alice], which is an array
    if let hands = snapshot["hands"] {
        // Should be an array value (the filtered result for alice)
        #expect(hands.arrayValue != nil, "Hands should be an array for perPlayer policy")
        if let handsArray = hands.arrayValue {
            #expect(handsArray.count == 2, "Alice should see her 2 cards")
        }
    } else {
        Issue.record("Hands field should exist in snapshot")
    }
}

@Test("Different players get different snapshots")
func testSyncEngineSnapshot_DifferentPlayersGetDifferentSnapshots() throws {
    // Arrange
    var gameState = TestGameStateTree()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    gameState.hands[alice] = ["alice_card1"]
    gameState.hands[bob] = ["bob_card1"]
    
    let syncEngine = SyncEngine()
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: gameState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: gameState)
    
    // Assert
    // Both should see broadcast fields
    #expect(aliceSnapshot["round"]?.intValue == bobSnapshot["round"]?.intValue,
           "Broadcast fields should be the same for all players")
    
    // But perPlayer fields should be different
    // perPlayerDictionaryValue returns value[playerID], so it's the array value, not the dict
    if let aliceHands = aliceSnapshot["hands"]?.arrayValue,
       let bobHands = bobSnapshot["hands"]?.arrayValue {
        #expect(aliceHands.count == 1, "Alice should see her 1 card")
        #expect(bobHands.count == 1, "Bob should see his 1 card")
        // The arrays should be different
        #expect(aliceHands != bobHands, "Players should see different hands")
    } else {
        Issue.record("Hands should exist in both snapshots as arrays")
    }
}

// MARK: - SyncPolicy Behavior Tests

@Test("Broadcast policy syncs same data to all players")
func testSyncPolicy_Broadcast() throws {
    // Arrange
    var gameState = TestGameStateTree()
    gameState.players[PlayerID("alice")] = "Alice"
    gameState.round = 10
    
    let syncEngine = SyncEngine()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: gameState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: gameState)
    
    // Assert
    // Broadcast fields should be the same for all players
    #expect(aliceSnapshot["players"]?.objectValue?["alice"]?.stringValue ==
           bobSnapshot["players"]?.objectValue?["alice"]?.stringValue,
           "Broadcast field should be the same for all players")
    #expect(aliceSnapshot["round"]?.intValue == bobSnapshot["round"]?.intValue,
           "Broadcast field should be the same for all players")
}

@Test("ServerOnly policy excludes fields from snapshot")
func testSyncPolicy_ServerOnly() throws {
    // Arrange
    var gameState = TestGameStateTree()
    gameState.hiddenData = 42
    
    let syncEngine = SyncEngine()
    let player = PlayerID("alice")
    
    // Act
    let snapshot = try syncEngine.snapshot(for: player, from: gameState)
    
    // Assert
    #expect(snapshot["hiddenData"] == nil, "ServerOnly field should not appear in snapshot")
}

@Test("Internal fields are excluded from snapshot")
func testInternalFields_ExcludedFromSnapshot() throws {
    // Arrange
    var stateWithInternal = StateTreeWithInternal()
    stateWithInternal.players[PlayerID("alice")] = "Alice"
    stateWithInternal.lastProcessedTimestamp = Date()
    stateWithInternal.cache["key"] = "value"
    
    let syncEngine = SyncEngine()
    let player = PlayerID("alice")
    
    // Act
    let snapshot = try syncEngine.snapshot(for: player, from: stateWithInternal)
    
    // Assert
    // @Internal fields should not appear in snapshot
    #expect(snapshot["lastProcessedTimestamp"] == nil, "@Internal field should not appear in snapshot")
    #expect(snapshot["cache"] == nil, "@Internal field should not appear in snapshot")
    
    // @Sync fields should still appear
    #expect(snapshot["players"] != nil, "@Sync field should appear in snapshot")
}

@Test("PerPlayer policy filters data per player")
func testSyncPolicy_PerPlayer() throws {
    // Arrange
    var gameState = TestGameStateTree()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    gameState.hands[alice] = ["alice_card"]
    gameState.hands[bob] = ["bob_card"]
    
    let syncEngine = SyncEngine()
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: gameState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: gameState)
    
    // Assert
    // perPlayerDictionaryValue returns value[playerID], so it's the array, not the dict
    if let aliceHands = aliceSnapshot["hands"]?.arrayValue {
        #expect(aliceHands.count == 1, "Alice should see her 1 card")
        if let firstCard = aliceHands.first?.stringValue {
            #expect(firstCard == "alice_card", "Alice should see her card")
        }
    } else {
        Issue.record("Alice should have hands field in snapshot as array")
    }
    
    // Bob should only see his own hands
    if let bobHands = bobSnapshot["hands"]?.arrayValue {
        #expect(bobHands.count == 1, "Bob should see his 1 card")
        if let firstCard = bobHands.first?.stringValue {
            #expect(firstCard == "bob_card", "Bob should see his card")
        }
    } else {
        Issue.record("Bob should have hands field in snapshot as array")
    }
}

// MARK: - Edge Cases

@Test("StateTree handles nil optional fields")
func testStateTree_WithNilOptionalFields() throws {
    // Test StateTree with optional fields
    @StateTreeBuilder
    struct OptionalStateTree: StateTreeProtocol {
        @Sync(.broadcast)
        var optionalValue: String? = nil
    }
    
    let state = OptionalStateTree()
    let syncEngine = SyncEngine()
    let player = PlayerID("test")
    
    // Act
    let snapshot = try syncEngine.snapshot(for: player, from: state)
    
    // Assert
    // Optional nil values should be handled
    if let optionalValue = snapshot["optionalValue"] {
        #expect(optionalValue == .null, "Nil optional should be represented as null")
    }
}

@Test("StateTree detects multiple sync policies")
func testStateTree_MultipleSyncPolicies() {
    // Arrange
    let gameState = TestGameStateTree()
    
    // Act
    let fields = gameState.getSyncFields()
    
    // Assert
    #expect(fields.count >= 1, "Should have at least one sync field")
    
    // Verify different policy types are detected
    let policyTypes = Set(fields.map { $0.policyType })
    #expect(!policyTypes.isEmpty, "Should detect policy types")
}
