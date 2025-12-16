// Tests/SwiftStateTreeTests/StateTreeTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Nested Structure Definitions

/// Test nested structure: Player state with multiple fields
struct TestPlayerState: StateProtocol {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

/// Test nested structure: Hand state containing cards
struct TestHandState: StateProtocol {
    var ownerID: PlayerID
    var cards: [TestCard]
}

/// Test nested structure: Card with multiple properties
struct TestCard: StateProtocol {
    let id: Int
    let suit: Int
    let rank: Int
}

// MARK: - Test StateNode Examples

/// Test StateNode with various sync policies
@StateNodeBuilder
struct TestGameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.serverOnly)
    var hiddenData: Int = 0
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: [String]] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

/// Test StateNode with all fields marked with @Sync
@StateNodeBuilder
struct CompleteStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var publicData: String = "public"
    
    @Sync(.serverOnly)
    var privateData: Int = 42
}

/// Test StateNode with @Internal fields
@StateNodeBuilder
struct StateNodeWithInternal: StateNodeProtocol {
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

/// Test StateNode with no fields (edge case)
@StateNodeBuilder
struct EmptyStateNode: StateNodeProtocol {
    // No fields
}

/// Test StateNode with nested struct structures
@StateNodeBuilder
struct NestedStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: TestPlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: TestHandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [TestCard] = []
    
    @Sync(.broadcast)
    var round: Int = 0
}

// MARK: - StateNode Protocol Tests

// MARK: - Protocol Conformance Tests

@Test("StateNode types can conform to StateNodeProtocol")
func testStateNodeProtocolConformance() {
    // Test that types can conform to StateNodeProtocol
    let gameState = TestGameStateRootNode()
    let _: StateNodeProtocol = gameState
    
    let emptyState = EmptyStateNode()
    let _: StateNodeProtocol = emptyState
    
    // If we can assign to StateNodeProtocol, conformance is verified
    #expect(Bool(true), "Types conform to StateNodeProtocol")
}

@Test("StateTree types are Sendable")
func testStateTreeIsSendable() {
    // Test that StateTree types are Sendable
    let gameState = TestGameStateRootNode()
    
    // This should compile without errors, indicating Sendable conformance
    let _: any Sendable = gameState
}

// MARK: - getSyncFields Tests

@Test("getSyncFields returns all sync fields")
func testGetSyncFields_ReturnsAllSyncFields() {
    // Arrange
    var gameState = TestGameStateRootNode()
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
    let emptyState = EmptyStateNode()
    
    // Act
    let fields = emptyState.getSyncFields()
    
    // Assert
    #expect(fields.count == 0, "Empty StateTree should have no sync fields")
}

@Test("getSyncFields normalizes field names")
func testGetSyncFields_FieldNamesAreNormalized() {
    // Arrange
    let gameState = TestGameStateRootNode()
    
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
    let completeState = CompleteStateNode()
    
    // Act
    let isValid = completeState.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "StateTree with all fields marked with @Sync should validate")
}

@Test("validateSyncFields returns true when fields have @Sync or @Internal")
func testValidateSyncFields_WithInternalFields() {
    // Arrange
    let stateWithInternal = StateNodeWithInternal()
    
    // Act
    let isValid = stateWithInternal.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "StateTree with @Sync and @Internal fields should validate")
}

@Test("validateSyncFields returns true for empty StateTree")
func testValidateSyncFields_EmptyStateTree() {
    // Arrange
    let emptyState = EmptyStateNode()
    
    // Act
    let isValid = emptyState.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "Empty StateTree should validate (no fields to check)")
}

// MARK: - Integration with SyncEngine Tests

@Test("SyncEngine snapshot works with StateTree")
func testSyncEngineSnapshot_WithStateTree() throws {
    // Arrange
    var gameState = TestGameStateRootNode()
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
    
    // PerPlayer fields: perPlayerSlice returns a dictionary slice with only this player's key
    // So for alice, it returns {"alice": ["card1", "card2"]}
    if let hands = snapshot["hands"] {
        // Should be a dictionary with only alice's key
        #expect(hands.objectValue != nil, "Hands should be a dictionary for perPlayerSlice policy")
        if let handsDict = hands.objectValue {
            #expect(handsDict["alice"] != nil, "Hands should contain alice's key")
            if let aliceHands = handsDict["alice"]?.arrayValue {
                #expect(aliceHands.count == 2, "Alice should see her 2 cards")
                // Verify actual card values
                #expect(aliceHands[0].stringValue == "card1", "First card should be 'card1'")
                #expect(aliceHands[1].stringValue == "card2", "Second card should be 'card2'")
            }
        }
    } else {
        Issue.record("Hands field should exist in snapshot")
    }
}

@Test("Different players get different snapshots")
func testSyncEngineSnapshot_DifferentPlayersGetDifferentSnapshots() throws {
    // Arrange
    var gameState = TestGameStateRootNode()
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
    // perPlayerSlice returns a dictionary slice: {"alice": [...]} or {"bob": [...]}
    if let aliceHandsDict = aliceSnapshot["hands"]?.objectValue,
       let bobHandsDict = bobSnapshot["hands"]?.objectValue {
        if let aliceHands = aliceHandsDict["alice"]?.arrayValue,
           let bobHands = bobHandsDict["bob"]?.arrayValue {
            #expect(aliceHands.count == 1, "Alice should see her 1 card")
            #expect(bobHands.count == 1, "Bob should see his 1 card")
            // The arrays should be different
            #expect(aliceHands != bobHands, "Players should see different hands")
        } else {
            Issue.record("Hands should contain player keys")
        }
    } else {
        Issue.record("Hands should exist in both snapshots as dictionaries")
    }
}

// MARK: - SyncPolicy Behavior Tests

@Test("Broadcast policy syncs same data to all players")
func testSyncPolicy_Broadcast() throws {
    // Arrange
    var gameState = TestGameStateRootNode()
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
    var gameState = TestGameStateRootNode()
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
    var stateWithInternal = StateNodeWithInternal()
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
    var gameState = TestGameStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    gameState.hands[alice] = ["alice_card"]
    gameState.hands[bob] = ["bob_card"]
    
    let syncEngine = SyncEngine()
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: gameState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: gameState)
    
    // Assert
    // perPlayerSlice returns a dictionary slice: {"alice": [...]} or {"bob": [...]}
    if let aliceHandsDict = aliceSnapshot["hands"]?.objectValue {
        if let aliceHands = aliceHandsDict["alice"]?.arrayValue {
            #expect(aliceHands.count == 1, "Alice should see her 1 card")
            if let firstCard = aliceHands.first?.stringValue {
                #expect(firstCard == "alice_card", "Alice should see her card")
            }
        } else {
            Issue.record("Alice's hands should contain 'alice' key")
        }
    } else {
        Issue.record("Alice should have hands field in snapshot as dictionary")
    }
    
    // Bob should only see his own hands
    if let bobHandsDict = bobSnapshot["hands"]?.objectValue {
        if let bobHands = bobHandsDict["bob"]?.arrayValue {
            #expect(bobHands.count == 1, "Bob should see his 1 card")
            if let firstCard = bobHands.first?.stringValue {
                #expect(firstCard == "bob_card", "Bob should see his card")
            }
        } else {
            Issue.record("Bob's hands should contain 'bob' key")
        }
    } else {
        Issue.record("Bob should have hands field in snapshot as dictionary")
    }
}

// MARK: - Edge Cases

@Test("StateTree handles nil optional fields")
func testStateTree_WithNilOptionalFields() throws {
    // Test StateTree with optional fields
    @StateNodeBuilder
    struct OptionalStateNode: StateNodeProtocol {
        @Sync(.broadcast)
        var optionalValue: String? = nil
    }
    
    let state = OptionalStateNode()
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
    let gameState = TestGameStateRootNode()
    
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
    let nestedState = NestedStateRootNode()
    
    // Assert
    #expect(nestedState.players.isEmpty, "Initial players should be empty")
    #expect(nestedState.hands.isEmpty, "Initial hands should be empty")
    #expect(nestedState.hiddenDeck.isEmpty, "Initial hiddenDeck should be empty")
    #expect(nestedState.round == 0, "Initial round should be 0")
}

@Test("Nested struct structures are properly serialized in snapshot")
func testNestedStateTree_Serialization() throws {
    // Arrange
    var nestedState = NestedStateRootNode()
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
        // perPlayerSlice returns a dictionary slice: {"alice": TestHandState}
        #expect(hands.objectValue != nil, "Hands should be a dictionary")
        
        if let handsDict = hands.objectValue {
            #expect(handsDict["alice"] != nil, "Hands should contain alice's key")
            if let handState = handsDict["alice"]?.objectValue {
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
            Issue.record("Hands should be a dictionary")
        }
    } else {
        Issue.record("Hands should exist in snapshot")
    }
}

@Test("Nested structures work with perPlayer policy")
func testNestedStateTree_PerPlayerPolicy() throws {
    // Arrange
    var nestedState = NestedStateRootNode()
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
    // Alice should only see her own hand (as a dictionary slice: {"alice": {...}})
    if let aliceHandsDict = aliceSnapshot["hands"]?.objectValue {
        if let aliceHand = aliceHandsDict["alice"]?.objectValue {
            if let aliceCards = aliceHand["cards"]?.arrayValue {
                #expect(aliceCards.count == 2, "Alice should see her 2 cards")
                #expect(aliceCards.first?.objectValue?["id"]?.intValue == 1, "Alice's first card id should be 1")
            }
        } else {
            Issue.record("Alice's hands should contain 'alice' key")
        }
    } else {
        Issue.record("Alice should have hands field in snapshot")
    }
    
    // Bob should only see his own hand (as a dictionary slice: {"bob": {...}})
    if let bobHandsDict = bobSnapshot["hands"]?.objectValue {
        if let bobHand = bobHandsDict["bob"]?.objectValue {
            if let bobCards = bobHand["cards"]?.arrayValue {
                #expect(bobCards.count == 1, "Bob should see his 1 card")
                #expect(bobCards.first?.objectValue?["id"]?.intValue == 3, "Bob's first card id should be 3")
            }
        } else {
            Issue.record("Bob's hands should contain 'bob' key")
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
    var nestedState = NestedStateRootNode()
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
    let nestedState = NestedStateRootNode()
    
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
    let nestedState = NestedStateRootNode()
    
    // Act
    let isValid = nestedState.validateSyncFields()
    
    // Assert
    #expect(isValid == true, "StateTree with nested structures should validate")
}

// MARK: - Recursive Filtering Tests

/// Test nested StateNode structure with perPlayer field inside
@StateNodeBuilder
struct TestPlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var position: Vec2 = Vec2(x: 0.0, y: 0.0)
    
    @Sync(.broadcast)
    var hp: Int = 0
    
    @Sync(.perPlayer { inventory, pid in
        // Return same type (dictionary with only this player's value)
        if let element = inventory[pid] {
            return [pid: element]
        }
        return nil
    })
    var inventory: [PlayerID: [String]] = [:]
}

/// Vec2 helper struct for testing
struct Vec2: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

/// Test root node with nested StateNode that has perPlayer field
@StateNodeBuilder
struct TestRoomStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: TestPlayerStateNode] = [:]
}

@Test("Recursive filtering: nested StateNode with perPlayer field correctly filters")
func testRecursiveFiltering_NestedStateNodeWithPerPlayerField() throws {
    // Arrange
    var roomState = TestRoomStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    // Create player states with different inventories
    var aliceState = TestPlayerStateNode()
    aliceState.position = Vec2(x: 10.0, y: 20.0)
    aliceState.hp = 100
    aliceState.inventory[alice] = ["sword", "shield"]
    aliceState.inventory[bob] = ["potion"]
    
    var bobState = TestPlayerStateNode()
    bobState.position = Vec2(x: 30.0, y: 40.0)
    bobState.hp = 80
    bobState.inventory[alice] = ["bow"]
    bobState.inventory[bob] = ["arrow", "quiver"]
    
    roomState.players[alice] = aliceState
    roomState.players[bob] = bobState
    
    let syncEngine = SyncEngine()
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: roomState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: roomState)
    
    // Assert
    // Both should see the players dictionary (broadcast)
    #expect(aliceSnapshot["players"] != nil, "Alice should see players field")
    #expect(bobSnapshot["players"] != nil, "Bob should see players field")
    
    if let players = aliceSnapshot["players"]?.objectValue {
        // Alice should see her own player state
        if let alicePlayerState = players["alice"]?.objectValue {
            // Broadcast fields should be visible
            #expect(alicePlayerState["position"] != nil, "Alice should see her position (broadcast)")
            #expect(alicePlayerState["hp"]?.intValue == 100, "Alice should see her hp (broadcast)")
            
            // PerPlayer field: Alice should only see her own inventory
            // Note: filteredValue returns [PlayerID: [String]] (dictionary), not [String] (array)
            // The structure is: {"alice": ["sword", "shield"]}
            if let aliceInventoryDict = alicePlayerState["inventory"]?.objectValue {
                // Extract Alice's items from the dictionary
                if let aliceItems = aliceInventoryDict["alice"]?.arrayValue {
                    #expect(aliceItems.count == 2, "Alice should see 2 items in her inventory")
                    let items = aliceItems.compactMap { $0.stringValue }
                    #expect(items.contains("sword"), "Alice should see sword in her inventory")
                    #expect(items.contains("shield"), "Alice should see shield in her inventory")
                    #expect(!items.contains("potion"), "Alice should NOT see Bob's potion in her inventory")
                } else {
                    Issue.record("Alice should have her own items in inventory dictionary")
                }
            } else {
                Issue.record("Alice should have inventory field in snapshot")
            }
        }
        
        // Alice should also see Bob's player state (broadcast)
        if let bobPlayerState = players["bob"]?.objectValue {
            // Broadcast fields should be visible
            #expect(bobPlayerState["position"] != nil, "Alice should see Bob's position (broadcast)")
            #expect(bobPlayerState["hp"]?.intValue == 80, "Alice should see Bob's hp (broadcast)")
            
            // PerPlayer field: Alice should see Bob's inventory filtered for Alice
            // Since Bob's inventory[alice] = ["bow"], Alice should see {"alice": ["bow"]}
            // Note: filteredValue returns [PlayerID: [String]] (dictionary), not [String] (array)
            if let bobInventoryDict = bobPlayerState["inventory"]?.objectValue {
                // Extract Alice's items from Bob's inventory dictionary
                if let aliceItemsInBobInventory = bobInventoryDict["alice"]?.arrayValue {
                    #expect(aliceItemsInBobInventory.count == 1, "Alice should see 1 item in Bob's inventory (filtered for Alice)")
                    #expect(aliceItemsInBobInventory.first?.stringValue == "bow", "Alice should see 'bow' in Bob's inventory (filtered for Alice)")
                } else {
                    Issue.record("Alice should have items in Bob's inventory dictionary (keyed by alice)")
                }
            } else {
                Issue.record("Alice should have inventory field for Bob in snapshot")
            }
        }
    }
    
    // Verify Bob's snapshot
    if let players = bobSnapshot["players"]?.objectValue {
        // Bob should see his own player state
        if let bobPlayerState = players["bob"]?.objectValue {
            // PerPlayer field: Bob should only see his own inventory
            // Note: filteredValue returns [PlayerID: [String]] (dictionary), not [String] (array)
            // The structure is: {"bob": ["arrow", "quiver"]}
            if let bobInventoryDict = bobPlayerState["inventory"]?.objectValue {
                // Extract Bob's items from the dictionary
                if let bobItems = bobInventoryDict["bob"]?.arrayValue {
                    #expect(bobItems.count == 2, "Bob should see 2 items in his inventory")
                    let items = bobItems.compactMap { $0.stringValue }
                    #expect(items.contains("arrow"), "Bob should see arrow in his inventory")
                    #expect(items.contains("quiver"), "Bob should see quiver in his inventory")
                } else {
                    Issue.record("Bob should have his own items in inventory dictionary")
                }
            } else {
                Issue.record("Bob should have inventory field in snapshot")
            }
        }
        
        // Bob should see Alice's player state (broadcast)
        if let alicePlayerState = players["alice"]?.objectValue {
            // PerPlayer field: Bob should see Alice's inventory filtered for Bob
            // Since Alice's inventory[bob] = ["potion"], Bob should see {"bob": ["potion"]}
            // Note: filteredValue returns [PlayerID: [String]] (dictionary), not [String] (array)
            if let aliceInventoryDict = alicePlayerState["inventory"]?.objectValue {
                // Extract Bob's items from Alice's inventory dictionary
                if let bobItemsInAliceInventory = aliceInventoryDict["bob"]?.arrayValue {
                    #expect(bobItemsInAliceInventory.count == 1, "Bob should see 1 item in Alice's inventory (filtered for Bob)")
                    #expect(bobItemsInAliceInventory.first?.stringValue == "potion", "Bob should see 'potion' in Alice's inventory (filtered for Bob)")
                } else {
                    Issue.record("Bob should have items in Alice's inventory dictionary (keyed by bob)")
                }
            } else {
                Issue.record("Bob should have inventory field for Alice in snapshot")
            }
        }
    }
}

@Test("Recursive filtering: nested StateNode with broadcast fields are same, perPlayer fields differ")
func testRecursiveFiltering_NestedStateNodeBroadcastFields() throws {
    // Arrange
    var roomState = TestRoomStateRootNode()
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    var playerState = TestPlayerStateNode()
    playerState.position = Vec2(x: 10.0, y: 20.0)
    playerState.hp = 100
    playerState.inventory[alice] = ["sword"]
    playerState.inventory[bob] = ["shield"]
    
    roomState.players[alice] = playerState
    
    let syncEngine = SyncEngine()
    
    // Act
    let aliceSnapshot = try syncEngine.snapshot(for: alice, from: roomState)
    let bobSnapshot = try syncEngine.snapshot(for: bob, from: roomState)
    
    // Assert
    // Note: The entire players dictionary will NOT be the same because perPlayer fields differ
    // But broadcast fields within each player state should be the same
    
    if let alicePlayers = aliceSnapshot["players"]?.objectValue?["alice"]?.objectValue,
       let bobPlayers = bobSnapshot["players"]?.objectValue?["alice"]?.objectValue {
        // Broadcast fields should be the same for both players
        #expect(alicePlayers["position"] == bobPlayers["position"], "Both should see the same position (broadcast)")
        #expect(alicePlayers["hp"] == bobPlayers["hp"], "Both should see the same hp (broadcast)")
        
        // But perPlayer fields should be different
        // Note: filteredValue returns [PlayerID: [String]] (dictionary), not [String] (array)
        // Alice sees: {"alice": ["sword"]}
        // Bob sees: {"bob": ["shield"]}
        let aliceInventoryDict = alicePlayers["inventory"]?.objectValue
        let bobInventoryDict = bobPlayers["inventory"]?.objectValue
        
        #expect(aliceInventoryDict != bobInventoryDict, "Inventories should be different (perPlayer filtering)")
        
        // Extract Alice's items from her view
        if let aliceItems = aliceInventoryDict?["alice"]?.arrayValue {
            #expect(aliceItems.count == 1, "Alice should see 1 item in her inventory")
            #expect(aliceItems.first?.stringValue == "sword", "Alice should see sword")
        } else {
            Issue.record("Alice should have her own items in inventory dictionary")
        }
        
        // Extract Bob's items from his view (filtered for Bob)
        if let bobItems = bobInventoryDict?["bob"]?.arrayValue {
            #expect(bobItems.count == 1, "Bob should see 1 item in Alice's inventory (filtered for Bob)")
            #expect(bobItems.first?.stringValue == "shield", "Bob should see shield (filtered for Bob)")
        } else {
            Issue.record("Bob should have items in inventory dictionary (keyed by bob)")
        }
    }
}

// MARK: - Container Helper Methods Tests

/// Test StateNode with Dictionary container type
@StateNodeBuilder
struct TestDictionaryStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

@Test("Macro generates helper methods for Dictionary container type")
func testContainerHelperMethods_Dictionary() {
    // Arrange
    var state = TestDictionaryStateNode()
    let alice = PlayerID("alice")
    
    // Act: Use generated helper method
    state.updatePlayers("Alice", forKey: alice)
    
    // Assert
    #expect(state.players[alice] == "Alice", "Player should be updated")
    #expect(state.isDirty() == true, "Should be dirty after using helper method")
    #expect(state.getDirtyFields().contains("players"), "Should contain 'players' in dirty fields")
    
    // Test remove helper method
    state.clearDirty()
    let removed = state.removePlayers(forKey: alice)
    #expect(removed == "Alice", "Should return removed value")
    #expect(state.players[alice] == nil, "Player should be removed")
    #expect(state.isDirty() == true, "Should be dirty after remove")
    #expect(state.getDirtyFields().contains("players"), "Should contain 'players' in dirty fields")
}

/// Test StateNode with Array container type
@StateNodeBuilder
struct TestArrayStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var cards: [String] = []
}

@Test("Macro generates helper methods for Array container type")
func testContainerHelperMethods_Array() {
    // Arrange
    var state = TestArrayStateNode()
    
    // Act: Use generated helper method
    state.appendCards("card1")
    
    // Assert
    #expect(state.cards.count == 1, "Should have 1 card")
    #expect(state.isDirty() == true, "Should be dirty after append")
    #expect(state.getDirtyFields().contains("cards"), "Should contain 'cards' in dirty fields")
    
    // Test remove helper method
    state.clearDirty()
    let removed = state.removeCards(at: 0)
    #expect(removed == "card1", "Should return removed card")
    #expect(state.cards.count == 0, "Should have 0 cards after removal")
    #expect(state.isDirty() == true, "Should be dirty after remove")
    #expect(state.getDirtyFields().contains("cards"), "Should contain 'cards' in dirty fields")
    
    // Test insert helper method
    state.clearDirty()
    state.insertCards("card0", at: 0)
    #expect(state.cards.count == 1, "Should have 1 card after insert")
    #expect(state.cards[0] == "card0", "First card should be card0")
    #expect(state.isDirty() == true, "Should be dirty after insert")
    #expect(state.getDirtyFields().contains("cards"), "Should contain 'cards' in dirty fields")
}

/// Test StateNode with Set container type
@StateNodeBuilder
struct TestSetStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var readyPlayers: Set<PlayerID> = []
}

@Test("Macro generates helper methods for Set container type")
func testContainerHelperMethods_Set() {
    // Arrange
    var state = TestSetStateNode()
    let alice = PlayerID("alice")
    
    // Act: Use generated helper method
    let insertResult = state.insertReadyPlayers(alice)
    
    // Assert
    #expect(insertResult.inserted == true, "Should insert successfully")
    #expect(state.readyPlayers.contains(alice), "Should contain alice")
    #expect(state.isDirty() == true, "Should be dirty after insert (when actually inserted)")
    #expect(state.getDirtyFields().contains("readyPlayers"), "Should contain 'readyPlayers' in dirty fields")
    
    // Test remove helper method
    state.clearDirty()
    let removed = state.removeReadyPlayers(alice)
    #expect(removed == alice, "Should return removed player")
    #expect(state.readyPlayers.contains(alice) == false, "Should not contain alice after removal")
    #expect(state.isDirty() == true, "Should be dirty after remove")
    #expect(state.getDirtyFields().contains("readyPlayers"), "Should contain 'readyPlayers' in dirty fields")
    
    // Test insert when element already exists (still marks dirty)
    // First, re-insert alice so it exists
    state.clearDirty()
    let reinsertResult = state.insertReadyPlayers(alice)
    #expect(reinsertResult.inserted == true, "Should insert successfully")
    #expect(state.isDirty() == true, "Should be dirty after insert")
    
    // Now try to insert again (duplicate) - still marks dirty (by design)
    // Note: Helper methods always mark dirty, even if the operation didn't change the value
    state.clearDirty()
    let insertResult2 = state.insertReadyPlayers(alice)
    #expect(insertResult2.inserted == false, "Should not insert duplicate")
    // Note: The helper method always marks dirty, even if inserted == false
    // This is by design: any set operation marks the field as dirty
    #expect(state.isDirty() == true, "Should be dirty even if element already exists (by design)")
    #expect(state.getDirtyFields().contains("readyPlayers"), "Should contain 'readyPlayers' in dirty fields")
}

// MARK: - Dirty Tracking Tests

/// Test StateNode with multiple @Sync fields for dirty tracking
@StateNodeBuilder
struct TestDirtyTrackingStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var round: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var score: Int = 0
}

@Test("StateNode isDirty() returns true when any field is dirty")
func testIsDirty_ReturnsTrueWhenAnyFieldIsDirty() {
    // Arrange
    var state = TestDirtyTrackingStateNode()
    
    // Act & Assert: Initially should be clean
    #expect(state.isDirty() == false, "Initially should not be dirty")
    
    // Modify a field
    state.round = 10
    #expect(state.isDirty() == true, "Should be dirty after modifying round")
    
    // Clear dirty
    state.clearDirty()
    #expect(state.isDirty() == false, "Should not be dirty after clear")
    
    // Modify another field
    state.score = 100
    #expect(state.isDirty() == true, "Should be dirty after modifying score")
}

@Test("StateNode getDirtyFields() returns correct set of dirty field names")
func testGetDirtyFields_ReturnsCorrectSet() {
    // Arrange
    var state = TestDirtyTrackingStateNode()
    
    // Act & Assert: Initially should be empty
    #expect(state.getDirtyFields().isEmpty == true, "Initially should have no dirty fields")
    
    // Modify one field
    state.round = 10
    let dirtyFields1 = state.getDirtyFields()
    #expect(dirtyFields1.count == 1, "Should have 1 dirty field")
    #expect(dirtyFields1.contains("round"), "Should contain 'round'")
    
    // Modify another field
    state.score = 100
    let dirtyFields2 = state.getDirtyFields()
    #expect(dirtyFields2.count == 2, "Should have 2 dirty fields")
    #expect(dirtyFields2.contains("round"), "Should contain 'round'")
    #expect(dirtyFields2.contains("score"), "Should contain 'score'")
    
    // Clear and verify
    state.clearDirty()
    #expect(state.getDirtyFields().isEmpty == true, "Should have no dirty fields after clear")
}

@Test("StateNode clearDirty() clears all dirty flags")
func testClearDirty_ClearsAllFlags() {
    // Arrange
    var state = TestDirtyTrackingStateNode()
    
    // Act: Modify multiple fields
    state.round = 10
    state.score = 100
    state.updatePlayers("Alice", forKey: PlayerID("alice"))
    
    // Assert: All should be dirty
    #expect(state.isDirty() == true, "Should be dirty")
    #expect(state.getDirtyFields().count == 3, "Should have 3 dirty fields")
    
    // Clear all
    state.clearDirty()
    
    // Assert: All should be clean
    #expect(state.isDirty() == false, "Should not be dirty after clear")
    #expect(state.getDirtyFields().isEmpty == true, "Should have no dirty fields after clear")
}

@Test("StateNode dirty tracking works with container helper methods")
func testDirtyTracking_WithContainerHelperMethods() {
    // Arrange
    var state = TestDirtyTrackingStateNode()
    let alice = PlayerID("alice")
    
    // Act: Use container helper method
    state.updatePlayers("Alice", forKey: alice)
    
    // Assert: Should be marked as dirty
    #expect(state.isDirty() == true, "Should be dirty after using helper method")
    #expect(state.getDirtyFields().contains("players"), "Should contain 'players' in dirty fields")
    
    // Clear and verify
    state.clearDirty()
    #expect(state.isDirty() == false, "Should not be dirty after clear")
    
    // Use another helper method
    state.removePlayers(forKey: alice)
    #expect(state.isDirty() == true, "Should be dirty after remove")
    #expect(state.getDirtyFields().contains("players"), "Should contain 'players' in dirty fields")
}

@Test("StateNode dirty tracking works with nested StateNode")
func testDirtyTracking_WithNestedStateNode() {
    // Arrange
    @StateNodeBuilder
    struct NestedTestStateNode: StateNodeProtocol {
        @Sync(.broadcast)
        var nestedValue: Int = 0
    }
    
    @StateNodeBuilder
    struct ParentTestStateNode: StateNodeProtocol {
        @Sync(.broadcast)
        var parentValue: Int = 0
        
        @Sync(.broadcast)
        var nested: NestedTestStateNode = NestedTestStateNode()
    }
    
    var state = ParentTestStateNode()
    
    // Act: Modify parent field
    state.parentValue = 10
    #expect(state.isDirty() == true, "Should be dirty after modifying parent field")
    #expect(state.getDirtyFields().contains("parentValue"), "Should contain 'parentValue'")
    
    // Clear
    state.clearDirty()
    #expect(state.isDirty() == false, "Should not be dirty after clear")
    // Verify that nested StateNode's dirty flag is also cleared (recursive clear)
    #expect(state.nested.isDirty() == false, "Nested StateNode should also be clean after parent clearDirty()")
    
    // Note: Modifying nested StateNode's fields does NOT automatically mark parent as dirty
    // Each StateNode tracks its own dirty state independently
    // The nested StateNode itself is a value, so modifying its internal fields
    // will mark the parent's "nested" field as dirty (because the nested value changed)
    state.nested.nestedValue = 20
    // The nested field itself is dirty because the nested StateNode instance changed
    #expect(state.isDirty() == true, "Should be dirty after modifying nested field (nested value changed)")
    #expect(state.getDirtyFields().contains("nested"), "Should contain 'nested'")
    
    // The nested StateNode also has its own dirty tracking
    #expect(state.nested.isDirty() == true, "Nested StateNode should also be dirty")
    #expect(state.nested.getDirtyFields().contains("nestedValue"), "Nested should contain 'nestedValue'")
}

@Test("StateNode clearDirty() recursively clears nested StateNode dirty flags to prevent unnecessary syncs")
func testClearDirty_RecursivelyClearsNestedStateNode() {
    // Arrange
    @StateNodeBuilder
    struct NestedTestStateNode: StateNodeProtocol {
        @Sync(.broadcast)
        var nestedValue: Int = 0
    }
    
    @StateNodeBuilder
    struct ParentTestStateNode: StateNodeProtocol {
        @Sync(.broadcast)
        var parentValue: Int = 0
        
        @Sync(.broadcast)
        var nested: NestedTestStateNode = NestedTestStateNode()
    }
    
    var state = ParentTestStateNode()
    
    // Act: Modify both parent and nested fields
    state.parentValue = 10
    state.nested.nestedValue = 20
    
    // Assert: Both should be dirty
    #expect(state.isDirty() == true, "Parent should be dirty")
    #expect(state.nested.isDirty() == true, "Nested should be dirty")
    #expect(state.getDirtyFields().contains("parentValue"), "Parent should contain 'parentValue'")
    #expect(state.getDirtyFields().contains("nested"), "Parent should contain 'nested'")
    #expect(state.nested.getDirtyFields().contains("nestedValue"), "Nested should contain 'nestedValue'")
    
    // Clear parent's dirty flags - this should also recursively clear nested StateNode's dirty flags
    state.clearDirty()
    
    // Assert: Both parent and nested should be clean after clearDirty()
    // This verifies that clearDirty() recursively clears nested StateNode's internal dirty flags,
    // preventing unnecessary comparisons in subsequent syncs when nested state hasn't changed.
    #expect(state.isDirty() == false, "Parent should not be dirty after clearDirty()")
    #expect(state.getDirtyFields().isEmpty == true, "Parent should have no dirty fields after clearDirty()")
    #expect(state.nested.isDirty() == false, "Nested StateNode should also be clean (clearDirty recurses)")
    #expect(state.nested.getDirtyFields().isEmpty == true, "Nested should have no dirty fields after clearDirty()")
}
