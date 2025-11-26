// Tests/SwiftStateTreeTests/SyncEnginePolicyTypeTests.swift
//
// 測試所有 SyncPolicy 類型：serverOnly, broadcast, perPlayer, masked, custom
// 確保每種 policy 類型都能正確工作

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test StateNode Definitions for Different Policy Types

/// Test node with masked policy
/// Note: For this test, we use a masked policy that returns the same type (Int) to avoid type casting issues
/// In real usage, masked can return different types, but macro-generated code assumes same type
@StateNodeBuilder
struct NodeWithMasked: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.masked { hp in
        // Mask HP: round to nearest 10 (returns Int, same type)
        return (hp / 10) * 10
    })
    var hp: Int = 100
}

/// Test node with custom policy
@StateNodeBuilder
struct NodeWithCustom: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.custom { playerID, data in
        // Only return data if playerID matches a condition
        if playerID.rawValue == "admin" {
            return data
        }
        return nil  // Non-admin players don't see this
    })
    var adminData: String = "secret"
}

/// Test node with direct perPlayer (not convenience method)
@StateNodeBuilder
struct NodeWithPerPlayer: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.perPlayer { inventory, playerID in
        // Direct perPlayer usage - return same type (dictionary with only this player's value)
        if let element = inventory[playerID] {
            return [playerID: element]
        }
        return nil
    })
    var inventory: [PlayerID: [String]] = [:]
}

/// Root node for testing all policy types
@StateNodeBuilder
struct RootNodeWithAllPolicies: StateNodeProtocol {
    @Sync(.broadcast)
    var broadcastField: String = "broadcast_value"
    
    @Sync(.serverOnly)
    var serverOnlyField: Int = 999
    
    @Sync(.perPlayer { dict, playerID in
        // Return same type (dictionary with only this player's value)
        if let element = dict[playerID] {
            return [playerID: element]
        }
        return nil
    })
    var perPlayerField: [PlayerID: String] = [:]
    
    @Sync(.masked { value in
        // Mask to show only first 3 characters
        String(value.prefix(3)) + "..."
    })
    var maskedField: String = "secret_password"
    
    @Sync(.custom { playerID, value in
        // Custom: only return if playerID starts with "a"
        if playerID.rawValue.hasPrefix("a") {
            return value
        }
        return nil
    })
    var customField: String = "custom_value"
    
    @Sync(.broadcast)
    var maskedNode: NodeWithMasked? = nil
    
    @Sync(.broadcast)
    var customNode: NodeWithCustom? = nil
    
    @Sync(.broadcast)
    var perPlayerNode: NodeWithPerPlayer? = nil
}

/// Suite for testing all policy types
@Suite("SyncPolicy Type Tests")
struct SyncEnginePolicyTypeTests {
    
    // MARK: - ServerOnly Tests
    
    @Test("ServerOnly: Field should not appear in snapshot")
    func testServerOnly_NotInSnapshot() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.serverOnlyField = 123
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        
        // Act
        let snapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert
        #expect(snapshot["serverOnlyField"] == nil, "ServerOnly field should not appear in snapshot")
        #expect(snapshot["broadcastField"] != nil, "Broadcast field should appear")
    }
    
    // MARK: - Broadcast Tests
    
    @Test("Broadcast: All players see same value")
    func testBroadcast_SameForAllPlayers() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.broadcastField = "shared_value"
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        // Act
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        let bobSnapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert
        #expect(aliceSnapshot["broadcastField"]?.stringValue == "shared_value")
        #expect(bobSnapshot["broadcastField"]?.stringValue == "shared_value")
        #expect(aliceSnapshot["broadcastField"] == bobSnapshot["broadcastField"], 
                "Broadcast field should be same for all players")
    }
    
    // MARK: - PerPlayer Tests
    
    @Test("PerPlayer: Each player sees different value")
    func testPerPlayer_DifferentForEachPlayer() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.perPlayerField[PlayerID("alice")] = "alice_data"
        state.perPlayerField[PlayerID("bob")] = "bob_data"
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        // Act
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        let bobSnapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert
        // perPlayer returns a dictionary with only this player's key: {"alice": "alice_data"}
        if let aliceDict = aliceSnapshot["perPlayerField"]?.objectValue {
            #expect(aliceDict["alice"]?.stringValue == "alice_data", 
                    "Alice should see her own data")
        } else {
            Issue.record("Alice's perPlayerField should be a dictionary")
        }
        if let bobDict = bobSnapshot["perPlayerField"]?.objectValue {
            #expect(bobDict["bob"]?.stringValue == "bob_data", 
                    "Bob should see his own data")
        } else {
            Issue.record("Bob's perPlayerField should be a dictionary")
        }
        #expect(aliceSnapshot["perPlayerField"] != bobSnapshot["perPlayerField"], 
                "PerPlayer field should be different for each player")
    }
    
    @Test("PerPlayer: Player without data sees nil")
    func testPerPlayer_NoDataReturnsNil() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.perPlayerField[PlayerID("alice")] = "alice_data"
        // Bob has no data
        let syncEngine = SyncEngine()
        let bob = PlayerID("bob")
        
        // Act
        let bobSnapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert
        #expect(bobSnapshot["perPlayerField"] == nil, 
                "Bob should not see perPlayerField if he has no data")
    }
    
    // MARK: - Masked Tests
    
    @Test("Masked: All players see same masked value")
    func testMasked_SameMaskedValueForAll() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.maskedField = "very_secret_password_123"
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        // Act
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        let bobSnapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert: maskedField uses masked policy that returns first 3 chars + "..."
        let expectedMasked = "ver..."  // First 3 chars + "..."
        #expect(aliceSnapshot["maskedField"]?.stringValue == expectedMasked, 
                "Alice should see masked value")
        #expect(bobSnapshot["maskedField"]?.stringValue == expectedMasked, 
                "Bob should see masked value")
        #expect(aliceSnapshot["maskedField"] == bobSnapshot["maskedField"], 
                "Masked field should be same for all players")
    }
    
    @Test("Masked: Nested node with masked field")
    func testMasked_NestedNode() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        let maskedNode = NodeWithMasked(name: "TestPlayer", hp: 85)
        state.maskedNode = maskedNode
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        
        // Act
        let snapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: masked HP should be rounded to nearest 10 (85 -> 80)
        if let maskedNodeValue = snapshot["maskedNode"]?.objectValue {
            #expect(maskedNodeValue["name"]?.stringValue == "TestPlayer", 
                    "Should see broadcast field")
            #expect(maskedNodeValue["hp"]?.intValue == 80, 
                    "Should see masked HP value (85 rounded to 80)")
        }
    }
    
    // MARK: - Custom Tests
    
    @Test("Custom: Conditional visibility based on playerID")
    func testCustom_ConditionalVisibility() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.customField = "secret_value"
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")  // Starts with "a"
        let bob = PlayerID("bob")      // Doesn't start with "a"
        
        // Act
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        let bobSnapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert
        #expect(aliceSnapshot["customField"]?.stringValue == "secret_value", 
                "Alice (starts with 'a') should see customField")
        #expect(bobSnapshot["customField"] == nil, 
                "Bob (doesn't start with 'a') should NOT see customField")
    }
    
    @Test("Custom: Nested node with custom policy")
    func testCustom_NestedNode() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        let customNode = NodeWithCustom(name: "Admin", adminData: "top_secret")
        state.customNode = customNode
        let syncEngine = SyncEngine()
        let admin = PlayerID("admin")
        let alice = PlayerID("alice")
        
        // Act
        let adminSnapshot = try syncEngine.snapshot(for: admin, from: state)
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert
        // Admin should see adminData
        if let adminCustomNode = adminSnapshot["customNode"]?.objectValue {
            #expect(adminCustomNode["name"]?.stringValue == "Admin", 
                    "Admin should see broadcast field")
            #expect(adminCustomNode["adminData"]?.stringValue == "top_secret", 
                    "Admin should see adminData")
        }
        
        // Alice should NOT see adminData
        if let aliceCustomNode = aliceSnapshot["customNode"]?.objectValue {
            #expect(aliceCustomNode["name"]?.stringValue == "Admin", 
                    "Alice should see broadcast field")
            #expect(aliceCustomNode["adminData"] == nil, 
                    "Alice should NOT see adminData (custom policy)")
        }
    }
    
    // MARK: - PerPlayer Direct Usage Tests
    
    @Test("PerPlayer: Direct usage (not convenience method)")
    func testPerPlayer_DirectUsage() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        var perPlayerNode = NodeWithPerPlayer(name: "TestPlayer")
        perPlayerNode.inventory[PlayerID("alice")] = ["sword", "shield"]
        perPlayerNode.inventory[PlayerID("bob")] = ["bow", "arrow"]
        state.perPlayerNode = perPlayerNode
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        // Act
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        let bobSnapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert
        // Alice's view
        if let aliceNode = aliceSnapshot["perPlayerNode"]?.objectValue {
            #expect(aliceNode["name"]?.stringValue == "TestPlayer", 
                    "Alice should see broadcast field")
            if let inventoryValue = aliceNode["inventory"] {
                if case .array(let arr) = inventoryValue {
                    #expect(arr.contains(.string("sword")), 
                            "Alice should see her own inventory")
                    #expect(arr.contains(.string("shield")), 
                            "Alice should see her own inventory")
                    #expect(!arr.contains(.string("bow")), 
                            "Alice should NOT see Bob's inventory")
                }
            }
        }
        
        // Bob's view
        if let bobNode = bobSnapshot["perPlayerNode"]?.objectValue {
            #expect(bobNode["name"]?.stringValue == "TestPlayer", 
                    "Bob should see broadcast field")
            if let inventoryValue = bobNode["inventory"] {
                if case .array(let arr) = inventoryValue {
                    #expect(arr.contains(.string("bow")), 
                            "Bob should see his own inventory")
                    #expect(arr.contains(.string("arrow")), 
                            "Bob should see his own inventory")
                    #expect(!arr.contains(.string("sword")), 
                            "Bob should NOT see Alice's inventory")
                }
            }
        }
    }
    
    // MARK: - Combined Policy Tests
    
    @Test("Combined: All policy types in one snapshot")
    func testCombined_AllPolicyTypes() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.broadcastField = "shared"
        state.perPlayerField[PlayerID("alice")] = "alice_data"
        state.maskedField = "secret123"
        state.customField = "custom_data"
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        
        // Act
        let snapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: Verify all visible fields
        #expect(snapshot["broadcastField"]?.stringValue == "shared", 
                "Should see broadcast field")
        // perPlayer returns a dictionary with only this player's key: {"alice": "alice_data"}
        if let perPlayerDict = snapshot["perPlayerField"]?.objectValue {
            #expect(perPlayerDict["alice"]?.stringValue == "alice_data", 
                    "Should see perPlayer field")
        } else {
            Issue.record("perPlayerField should be a dictionary")
        }
        #expect(snapshot["maskedField"]?.stringValue == "sec...", 
                "Should see masked field")
        #expect(snapshot["customField"]?.stringValue == "custom_data", 
                "Should see custom field (alice starts with 'a')")
        #expect(snapshot["serverOnlyField"] == nil, 
                "Should NOT see serverOnly field")
    }
    
    // MARK: - Edge Cases
    
    @Test("Masked: Empty string handling")
    func testMasked_EmptyString() throws {
        // Arrange
        var state = RootNodeWithAllPolicies()
        state.maskedField = ""
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        
        // Act
        let snapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: Masked function should handle empty string
        // First 3 chars of "" is "", so result should be "..."
        #expect(snapshot["maskedField"]?.stringValue == "...", 
                "Masked empty string should return '...'")
    }
    
    @Test("Custom: Returns nil for all players")
    func testCustom_ReturnsNilForAll() throws {
        // Arrange
        let state = RootNodeWithAllPolicies()
        // Custom policy only returns value if playerID starts with "a"
        // But we'll test with a player that doesn't match
        let syncEngine = SyncEngine()
        let bob = PlayerID("bob")
        
        // Act
        let snapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert
        #expect(snapshot["customField"] == nil, 
                "Bob should NOT see customField (doesn't start with 'a')")
    }
}

