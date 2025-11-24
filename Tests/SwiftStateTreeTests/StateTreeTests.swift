// Tests/SwiftStateTreeTests/StateTreeTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Nested Structure Definitions

/// Test nested structure: Player state with multiple fields
@State
struct TestPlayerState: StateProtocol {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

/// Test nested structure: Hand state containing cards
@State
struct TestHandState: StateProtocol {
    var ownerID: PlayerID
    var cards: [TestCard]
}

/// Test nested structure: Card with multiple properties
@State
struct TestCard: StateProtocol {
    let id: Int
    let suit: Int
    let rank: Int
}

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

/// Test StateTree with nested struct structures
@StateTreeBuilder
struct NestedStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: TestPlayerState] = [:]
    
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: TestHandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [TestCard] = []
    
    @Sync(.broadcast)
    var round: Int = 0
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
    
    // Verify broadcast field values
    #expect(snapshot["round"]?.intValue == 5, "Round should be 5")
    
    // Verify players dictionary content
    if let players = snapshot["players"]?.objectValue {
        #expect(players["alice"]?.stringValue == "Alice", "Alice's name should be 'Alice'")
        #expect(players["bob"]?.stringValue == "Bob", "Bob's name should be 'Bob'")
    } else {
        Issue.record("Players should exist in snapshot as object")
    }
    
    // ServerOnly fields should not be visible
    #expect(snapshot["hiddenData"] == nil, "ServerOnly field 'hiddenData' should not be in snapshot")
    
    // PerPlayer fields: perPlayerDictionaryValue returns value[playerID]
    // So for alice, it returns hands[alice], which is an array
    if let hands = snapshot["hands"] {
        // Should be an array value (the filtered result for alice)
        #expect(hands.arrayValue != nil, "Hands should be an array for perPlayer policy")
        if let handsArray = hands.arrayValue {
            #expect(handsArray.count == 2, "Alice should see her 2 cards")
            // Verify actual card values
            #expect(handsArray[0].stringValue == "card1", "First card should be 'card1'")
            #expect(handsArray[1].stringValue == "card2", "Second card should be 'card2'")
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

// MARK: - Nested Structure Tests

@Test("StateTree with nested struct structures can be created")
func testNestedStateTree_Creation() {
    // Arrange & Act
    let nestedState = NestedStateTree()
    
    // Assert
    #expect(nestedState.players.isEmpty, "Initial players should be empty")
    #expect(nestedState.hands.isEmpty, "Initial hands should be empty")
    #expect(nestedState.hiddenDeck.isEmpty, "Initial hiddenDeck should be empty")
    #expect(nestedState.round == 0, "Initial round should be 0")
}

@Test("Nested struct structures are properly serialized in snapshot")
func testNestedStateTree_Serialization() throws {
    // Arrange
    var nestedState = NestedStateTree()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    nestedState.players[alice] = TestPlayerState(name: "Alice", hpCurrent: 100, hpMax: 100)
    nestedState.players[bob] = TestPlayerState(name: "Bob", hpCurrent: 80, hpMax: 100)
    
    nestedState.hands[alice] = TestHandState(
        ownerID: alice,
        cards: [
            TestCard(id: 1, suit: 0, rank: 1),
            TestCard(id: 2, suit: 0, rank: 2)
        ]
    )
    
    nestedState.hiddenDeck = [
        TestCard(id: 99, suit: 3, rank: 13)
    ]
    
    nestedState.round = 5
    
    let syncEngine = SyncEngine()
    
    // Act
    let snapshot = try syncEngine.snapshot(for: alice, from: nestedState)
    
    // Assert
    // Broadcast fields should be visible
    #expect(snapshot["players"] != nil, "Broadcast field 'players' should be in snapshot")
    #expect(snapshot["round"] != nil, "Broadcast field 'round' should be in snapshot")
    
    // ServerOnly fields should not be visible
    #expect(snapshot["hiddenDeck"] == nil, "ServerOnly field 'hiddenDeck' should not be in snapshot")
    
    // Verify nested structure in players
    if let players = snapshot["players"]?.objectValue {
        #expect(players["alice"] != nil, "Alice's player state should be in snapshot")
        #expect(players["bob"] != nil, "Bob's player state should be in snapshot")
        
        // Verify nested structure fields
        if let aliceState = players["alice"]?.objectValue {
            #expect(aliceState["name"]?.stringValue == "Alice", "Alice's name should be correct")
            #expect(aliceState["hpCurrent"]?.intValue == 100, "Alice's hpCurrent should be correct")
            #expect(aliceState["hpMax"]?.intValue == 100, "Alice's hpMax should be correct")
        } else {
            Issue.record("Alice's player state should be an object")
        }
    } else {
        Issue.record("Players should exist in snapshot as object")
    }
    
    // Verify perPlayer hands structure
    if let hands = snapshot["hands"] {
        // perPlayerDictionaryValue returns the value for the player, which is TestHandState
        #expect(hands.objectValue != nil, "Hands should be an object (TestHandState)")
        
        if let handState = hands.objectValue {
            #expect(handState["ownerID"] != nil, "Hand state should contain ownerID")
            #expect(handState["cards"] != nil, "Hand state should contain cards")
            
            // Verify cards array
            if let cards = handState["cards"]?.arrayValue {
                #expect(cards.count == 2, "Alice should see her 2 cards")
                
                // Verify first card structure
                if let firstCard = cards.first?.objectValue {
                    #expect(firstCard["id"]?.intValue == 1, "First card id should be 1")
                    #expect(firstCard["suit"]?.intValue == 0, "First card suit should be 0")
                    #expect(firstCard["rank"]?.intValue == 1, "First card rank should be 1")
                }
            }
        }
    } else {
        Issue.record("Hands field should exist in snapshot")
    }
}

@Test("Nested structures work with perPlayer policy")
func testNestedStateTree_PerPlayerPolicy() throws {
    // Arrange
    var nestedState = NestedStateTree()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    nestedState.hands[alice] = TestHandState(
        ownerID: alice,
        cards: [
            TestCard(id: 1, suit: 0, rank: 1),
            TestCard(id: 2, suit: 0, rank: 2)
        ]
    )
    
    nestedState.hands[bob] = TestHandState(
        ownerID: bob,
        cards: [
            TestCard(id: 3, suit: 1, rank: 3)
        ]
    )
    
    let syncEngine = SyncEngine()
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: nestedState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: nestedState)
    
    // Assert
    // Alice should only see her own hand
    if let aliceHands = aliceSnapshot["hands"]?.objectValue {
        if let aliceCards = aliceHands["cards"]?.arrayValue {
            #expect(aliceCards.count == 2, "Alice should see her 2 cards")
            #expect(aliceCards.first?.objectValue?["id"]?.intValue == 1, "Alice's first card id should be 1")
        }
    } else {
        Issue.record("Alice should have hands field in snapshot")
    }
    
    // Bob should only see his own hand
    if let bobHands = bobSnapshot["hands"]?.objectValue {
        if let bobCards = bobHands["cards"]?.arrayValue {
            #expect(bobCards.count == 1, "Bob should see his 1 card")
            #expect(bobCards.first?.objectValue?["id"]?.intValue == 3, "Bob's first card id should be 3")
        }
    } else {
        Issue.record("Bob should have hands field in snapshot")
    }
    
    // Hands should be different for different players
    #expect(aliceSnapshot["hands"] != bobSnapshot["hands"], "Different players should see different hands")
}

@Test("Nested structures in broadcast fields are same for all players")
func testNestedStateTree_BroadcastNestedStructures() throws {
    // Arrange
    var nestedState = NestedStateTree()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    nestedState.players[alice] = TestPlayerState(name: "Alice", hpCurrent: 100, hpMax: 100)
    nestedState.players[bob] = TestPlayerState(name: "Bob", hpCurrent: 80, hpMax: 100)
    nestedState.round = 10
    
    let syncEngine = SyncEngine()
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: nestedState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: nestedState)
    
    // Assert
    // Broadcast fields should be the same for all players
    #expect(aliceSnapshot["players"] == bobSnapshot["players"], "Broadcast field 'players' should be the same for all players")
    #expect(aliceSnapshot["round"]?.intValue == bobSnapshot["round"]?.intValue,
           "Broadcast field 'round' should be the same for all players")
    
    // Verify nested structure is correctly serialized in broadcast field
    if let players = aliceSnapshot["players"]?.objectValue {
        #expect(players["alice"] != nil, "Alice's player state should be in snapshot")
        #expect(players["bob"] != nil, "Bob's player state should be in snapshot")
        
        // Both players should see the same players dictionary
        if let aliceState = players["alice"]?.objectValue,
           let bobState = players["bob"]?.objectValue {
            #expect(aliceState["name"]?.stringValue == "Alice", "Alice's name should be correct")
            #expect(bobState["name"]?.stringValue == "Bob", "Bob's name should be correct")
        }
    }
}

@Test("getSyncFields works with nested structures")
func testNestedStateTree_GetSyncFields() {
    // Arrange
    let nestedState = NestedStateTree()
    
    // Act
    let fields = nestedState.getSyncFields()
    
    // Assert
    #expect(fields.count == 4, "Should find 4 @Sync fields")
    
    let fieldNames = Set(fields.map { $0.name })
    #expect(fieldNames.contains("players"), "Should contain 'players' field")
    #expect(fieldNames.contains("hands"), "Should contain 'hands' field")
    #expect(fieldNames.contains("hiddenDeck"), "Should contain 'hiddenDeck' field")
    #expect(fieldNames.contains("round"), "Should contain 'round' field")
}

@Test("validateSyncFields works with nested structures")
func testNestedStateTree_ValidateSyncFields() {
    // Arrange
    let nestedState = NestedStateTree()
    
    // Act
    let isValid = nestedState.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "StateTree with nested structures should validate")
}
