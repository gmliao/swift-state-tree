// Tests/SwiftStateTreeTests/SyncEnginePolicyCombinationTests.swift
//
// 測試 Policy 組合：驗證不同 parent-child policy 組合的行為
// 驗證「篩子層層過濾 + 樹的深度優先遍歷」設計理念

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test StateNode Definitions for Policy Combinations

/// Level 2: Deep nested node
@StateNodeBuilder
struct DeepNestedNode: StateNodeProtocol {
    @Sync(.broadcast)
    var value: String = ""
    
    @Sync(.serverOnly)
    var secret: Int = 0
}

/// Level 1: Nested node with different policies
@StateNodeBuilder
struct NestedNodeWithBroadcast: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.broadcast)
    var nested: DeepNestedNode? = nil
}

@StateNodeBuilder
struct NestedNodeWithPerPlayer: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.perPlayerSlice())
    var items: [PlayerID: [String]] = [:]
}

/// Level 0: Root nodes with different parent policies
@StateNodeBuilder
struct RootNode_Broadcast_Broadcast: StateNodeProtocol {
    @Sync(.broadcast)  // Parent: broadcast
    var nodes: [PlayerID: NestedNodeWithBroadcast] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

@StateNodeBuilder
struct RootNode_Broadcast_PerPlayer: StateNodeProtocol {
    @Sync(.broadcast)  // Parent: broadcast
    var nodes: [PlayerID: NestedNodeWithPerPlayer] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

@StateNodeBuilder
struct RootNode_PerPlayer_Broadcast: StateNodeProtocol {
    @Sync(.perPlayerSlice())  // Parent: perPlayer
    var nodes: [PlayerID: NestedNodeWithBroadcast] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

@StateNodeBuilder
struct RootNode_PerPlayer_PerPlayer: StateNodeProtocol {
    @Sync(.perPlayerSlice())  // Parent: perPlayer
    var nodes: [PlayerID: NestedNodeWithPerPlayer] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

/// Three-level nested structure
@StateNodeBuilder
struct Level2Node: StateNodeProtocol {
    @Sync(.broadcast)
    var data: String = ""
}

@StateNodeBuilder
struct Level1Node: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.broadcast)
    var level2: Level2Node? = nil
}

@StateNodeBuilder
struct Level0RootNode: StateNodeProtocol {
    @Sync(.perPlayerSlice())
    var level1: [PlayerID: Level1Node] = [:]
}

/// Suite for testing policy combinations
@Suite("Policy Combination Tests")
struct SyncEnginePolicyCombinationTests {
    
    // MARK: - Basic Policy Combinations
    
    @Test("Policy Combination: Broadcast parent + Broadcast child")
    func testPolicyCombination_Broadcast_Broadcast() throws {
        // Arrange
        var state = RootNode_Broadcast_Broadcast()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        var aliceNode = NestedNodeWithBroadcast(name: "Alice")
        aliceNode.nested = DeepNestedNode(value: "alice_data", secret: 999)
        
        var bobNode = NestedNodeWithBroadcast(name: "Bob")
        bobNode.nested = DeepNestedNode(value: "bob_data", secret: 888)
        
        state.nodes[alice] = aliceNode
        state.nodes[bob] = bobNode
        state.round = 1
        
        // Act: Generate snapshot for Alice
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: Alice should see all nodes (broadcast parent)
        #expect(aliceSnapshot["nodes"] != nil, "Alice should see nodes field")
        if let nodesValue = aliceSnapshot["nodes"]?.objectValue {
            #expect(nodesValue["alice"] != nil, "Alice should see her own node")
            #expect(nodesValue["bob"] != nil, "Alice should see Bob's node (broadcast parent)")
            
            // Check nested structure
            if let aliceNodeValue = nodesValue["alice"]?.objectValue {
                #expect(aliceNodeValue["name"]?.stringValue == "Alice", "Alice should see her name")
                #expect(aliceNodeValue["nested"] != nil, "Alice should see nested node")
                if let nestedValue = aliceNodeValue["nested"]?.objectValue {
                    #expect(nestedValue["value"]?.stringValue == "alice_data", "Alice should see nested value")
                    #expect(nestedValue["secret"] == nil, "Alice should NOT see secret (serverOnly)")
                }
            }
            
            if let bobNodeValue = nodesValue["bob"]?.objectValue {
                #expect(bobNodeValue["name"]?.stringValue == "Bob", "Alice should see Bob's name")
                #expect(bobNodeValue["nested"] != nil, "Alice should see Bob's nested node")
            }
        }
        
        #expect(aliceSnapshot["round"]?.intValue == 1, "Alice should see round")
    }
    
    @Test("Policy Combination: Broadcast parent + PerPlayer child")
    func testPolicyCombination_Broadcast_PerPlayer() throws {
        // Arrange
        var state = RootNode_Broadcast_PerPlayer()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        var aliceNode = NestedNodeWithPerPlayer(name: "Alice")
        aliceNode.items[alice] = ["sword"]
        aliceNode.items[bob] = ["bow"]  // Alice shouldn't see this
        
        var bobNode = NestedNodeWithPerPlayer(name: "Bob")
        bobNode.items[bob] = ["arrow"]
        bobNode.items[alice] = ["potion"]  // Alice should see this
        
        state.nodes[alice] = aliceNode
        state.nodes[bob] = bobNode
        
        // Act: Generate snapshot for Alice
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: Alice should see all nodes, but items are filtered
        if let nodesValue = aliceSnapshot["nodes"]?.objectValue {
            // Alice's node
            if let aliceNodeValue = nodesValue["alice"]?.objectValue {
                #expect(aliceNodeValue["name"]?.stringValue == "Alice", "Alice should see her name")
                if let itemsValue = aliceNodeValue["items"] {
                    if case .array(let arr) = itemsValue {
                        #expect(arr.contains(.string("sword")), "Alice should see her own items")
                        #expect(!arr.contains(.string("bow")), "Alice should NOT see Bob's items in her node")
                    }
                }
            }
            
            // Bob's node
            if let bobNodeValue = nodesValue["bob"]?.objectValue {
                #expect(bobNodeValue["name"]?.stringValue == "Bob", "Alice should see Bob's name")
                if let itemsValue = bobNodeValue["items"] {
                    if case .array(let arr) = itemsValue {
                        #expect(arr.contains(.string("potion")), "Alice should see items she stored in Bob's node")
                        #expect(!arr.contains(.string("arrow")), "Alice should NOT see Bob's items")
                    }
                }
            }
        }
    }
    
    @Test("Policy Combination: PerPlayer parent + Broadcast child")
    func testPolicyCombination_PerPlayer_Broadcast() throws {
        // Arrange
        var state = RootNode_PerPlayer_Broadcast()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        var aliceNode = NestedNodeWithBroadcast(name: "Alice")
        aliceNode.nested = DeepNestedNode(value: "alice_data", secret: 999)
        
        var bobNode = NestedNodeWithBroadcast(name: "Bob")
        bobNode.nested = DeepNestedNode(value: "bob_data", secret: 888)
        
        state.nodes[alice] = aliceNode
        state.nodes[bob] = bobNode
        
        // Act: Generate snapshot for Alice
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: Alice should only see her own node (perPlayer parent)
        // But within that node, all broadcast fields are visible
        if let nodesValue = aliceSnapshot["nodes"] {
            // When parent is perPlayerSlice, it returns a dict with only alice's key: {"alice": {...}}
            if case .object(let nodesDict) = nodesValue {
                #expect(nodesDict["alice"] != nil, "Nodes should contain alice's key")
                if let aliceNode = nodesDict["alice"]?.objectValue {
                    #expect(aliceNode["name"]?.stringValue == "Alice", "Alice should see her name")
                    #expect(aliceNode["nested"] != nil, "Alice should see nested node")
                    if let nestedValue = aliceNode["nested"]?.objectValue {
                        #expect(nestedValue["value"]?.stringValue == "alice_data", "Alice should see nested value")
                        #expect(nestedValue["secret"] == nil, "Alice should NOT see secret (serverOnly)")
                    }
                }
                #expect(nodesDict["bob"] == nil, "Bob's node should not be visible")
            }
        }
    }
    
    @Test("Policy Combination: PerPlayer parent + PerPlayer child")
    func testPolicyCombination_PerPlayer_PerPlayer() throws {
        // Arrange
        var state = RootNode_PerPlayer_PerPlayer()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        var aliceNode = NestedNodeWithPerPlayer(name: "Alice")
        aliceNode.items[alice] = ["sword"]
        aliceNode.items[bob] = ["bow"]
        
        var bobNode = NestedNodeWithPerPlayer(name: "Bob")
        bobNode.items[bob] = ["arrow"]
        bobNode.items[alice] = ["potion"]
        
        state.nodes[alice] = aliceNode
        state.nodes[bob] = bobNode
        
        // Act: Generate snapshot for Alice
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: Alice should only see her own node, and items are filtered
        if let nodesValue = aliceSnapshot["nodes"] {
            // perPlayerSlice returns a dict with only alice's key: {"alice": {...}}
            if case .object(let nodesDict) = nodesValue {
                #expect(nodesDict["alice"] != nil, "Nodes should contain alice's key")
                if let aliceNode = nodesDict["alice"]?.objectValue {
                    #expect(aliceNode["name"]?.stringValue == "Alice", "Alice should see her name")
                    if let itemsValue = aliceNode["items"] {
                        // items is also perPlayerSlice, so it's a dict: {"alice": ["sword"]}
                        if case .object(let itemsDict) = itemsValue {
                            if let aliceItems = itemsDict["alice"]?.arrayValue {
                                #expect(aliceItems.contains(.string("sword")), "Alice should see her own items")
                                #expect(!aliceItems.contains(.string("bow")), "Alice should NOT see Bob's items in her node")
                            }
                        }
                    }
                }
                #expect(nodesDict["bob"] == nil, "Bob's node should not be visible")
            }
        }
    }
    
    // MARK: - Three-Level Nesting
    
    @Test("Policy Combination: Three-level nesting with perPlayer at root")
    func testPolicyCombination_ThreeLevelNesting() throws {
        // Arrange
        var state = Level0RootNode()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        var aliceLevel1 = Level1Node(name: "Alice")
        aliceLevel1.level2 = Level2Node(data: "alice_level2")
        
        var bobLevel1 = Level1Node(name: "Bob")
        bobLevel1.level2 = Level2Node(data: "bob_level2")
        
        state.level1[alice] = aliceLevel1
        state.level1[bob] = bobLevel1
        
        // Act: Generate snapshot for Alice
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: Verify three-level filtering
        // Level 0: perPlayerSlice → only alice's level1 node (as dict: {"alice": {...}})
        // Level 1: broadcast → all fields visible
        // Level 2: broadcast → all fields visible
        if let level1Value = aliceSnapshot["level1"] {
            // perPlayerSlice returns a dict with only alice's key
            if case .object(let level1Dict) = level1Value {
                #expect(level1Dict["alice"] != nil, "Level1 should contain alice's key")
                if let aliceLevel1 = level1Dict["alice"]?.objectValue {
                    #expect(aliceLevel1["name"]?.stringValue == "Alice", "Alice should see her name at level 1")
                    if let level2Value = aliceLevel1["level2"]?.objectValue {
                        #expect(level2Value["data"]?.stringValue == "alice_level2", "Alice should see level2 data")
                    }
                }
                #expect(level1Dict["bob"] == nil, "Bob's level1 should not be visible")
            }
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("Policy Combination: Empty nested node")
    func testPolicyCombination_EmptyNestedNode() throws {
        // Arrange
        var state = RootNode_Broadcast_Broadcast()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        
        var aliceNode = NestedNodeWithBroadcast(name: "Alice")
        aliceNode.nested = nil  // Empty nested node
        
        state.nodes[alice] = aliceNode
        
        // Act
        let snapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert
        if let nodesValue = snapshot["nodes"]?.objectValue {
            if let aliceNodeValue = nodesValue["alice"]?.objectValue {
                #expect(aliceNodeValue["name"]?.stringValue == "Alice", "Alice should see her name")
                // nested should be null or not present
                let nestedValue = aliceNodeValue["nested"]
                #expect(nestedValue == nil || nestedValue == .null, "Nested should be null or not present")
            }
        }
    }
    
    @Test("Policy Combination: ServerOnly field in nested node")
    func testPolicyCombination_ServerOnlyInNested() throws {
        // Arrange
        var state = RootNode_Broadcast_Broadcast()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        
        var aliceNode = NestedNodeWithBroadcast(name: "Alice")
        aliceNode.nested = DeepNestedNode(value: "data", secret: 123)
        
        state.nodes[alice] = aliceNode
        
        // Act
        let snapshot = try syncEngine.snapshot(for: alice, from: state)
        
        // Assert: ServerOnly field should not appear
        if let nodesValue = snapshot["nodes"]?.objectValue {
            if let aliceNodeValue = nodesValue["alice"]?.objectValue {
                if let nestedValue = aliceNodeValue["nested"]?.objectValue {
                    #expect(nestedValue["value"]?.stringValue == "data", "Should see broadcast field")
                    #expect(nestedValue["secret"] == nil, "Should NOT see serverOnly field")
                }
            }
        }
    }
    
    // MARK: - Multiple Players Comparison
    
    @Test("Policy Combination: Compare different players' views")
    func testPolicyCombination_ComparePlayerViews() throws {
        // Arrange
        var state = RootNode_Broadcast_PerPlayer()
        let syncEngine = SyncEngine()
        let alice = PlayerID("alice")
        let bob = PlayerID("bob")
        
        var aliceNode = NestedNodeWithPerPlayer(name: "Alice")
        aliceNode.items[alice] = ["sword"]
        aliceNode.items[bob] = ["bow"]
        
        var bobNode = NestedNodeWithPerPlayer(name: "Bob")
        bobNode.items[bob] = ["arrow"]
        bobNode.items[alice] = ["potion"]
        
        state.nodes[alice] = aliceNode
        state.nodes[bob] = bobNode
        
        // Act: Generate snapshots for both players
        let aliceSnapshot = try syncEngine.snapshot(for: alice, from: state)
        let bobSnapshot = try syncEngine.snapshot(for: bob, from: state)
        
        // Assert: Verify different views
        // Alice's view
        if let aliceNodesValue = aliceSnapshot["nodes"]?.objectValue {
            if let aliceNodeValue = aliceNodesValue["alice"]?.objectValue {
                if let itemsValue = aliceNodeValue["items"] {
                    if case .array(let arr) = itemsValue {
                        #expect(arr.contains(.string("sword")), "Alice should see her own items")
                        #expect(!arr.contains(.string("bow")), "Alice should NOT see Bob's items in her node")
                    }
                }
            }
            
            if let bobNodeValue = aliceNodesValue["bob"]?.objectValue {
                if let itemsValue = bobNodeValue["items"] {
                    if case .array(let arr) = itemsValue {
                        #expect(arr.contains(.string("potion")), "Alice should see items she stored in Bob's node")
                    }
                }
            }
        }
        
        // Bob's view
        if let bobNodesValue = bobSnapshot["nodes"]?.objectValue {
            if let bobNodeValue = bobNodesValue["bob"]?.objectValue {
                if let itemsValue = bobNodeValue["items"] {
                    if case .array(let arr) = itemsValue {
                        #expect(arr.contains(.string("arrow")), "Bob should see his own items")
                        #expect(!arr.contains(.string("potion")), "Bob should NOT see Alice's items in his node")
                    }
                }
            }
            
            if let aliceNodeValue = bobNodesValue["alice"]?.objectValue {
                if let itemsValue = aliceNodeValue["items"] {
                    if case .array(let arr) = itemsValue {
                        #expect(arr.contains(.string("bow")), "Bob should see items he stored in Alice's node")
                    }
                }
            }
        }
    }
}

