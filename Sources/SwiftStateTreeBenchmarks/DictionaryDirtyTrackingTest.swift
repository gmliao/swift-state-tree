// Sources/SwiftStateTreeBenchmarks/DictionaryDirtyTrackingTest.swift

import Foundation
import SwiftStateTree

/// Test to verify if Dictionary dirty tracking only serializes modified keys
/// or the entire Dictionary
func testDictionaryDirtyTracking() {
    print("\n🔍 Testing Dictionary Dirty Tracking...")
    print(String(repeating: "=", count: 60))
    
    // Create initial state with multiple players
    var state = generateTestState(playerCount: 10, cardsPerPlayer: 5)
    let playerID = PlayerID("player_0")
    
    // Get initial snapshot to establish baseline
    let syncEngine = SyncEngine()
    let initialSnapshot = try! syncEngine.snapshot(for: playerID, from: state)
    
    print("\n📊 Initial Snapshot:")
    print("  Keys: \(initialSnapshot.values.keys.sorted())")
    if let playerNodesValue = initialSnapshot.values["playerNodes"] {
        print("  playerNodes type: \(type(of: playerNodesValue))")
        // Try to inspect the structure
        if case .object(let dict) = playerNodesValue {
            print("  playerNodes contains \(dict.count) keys")
            print("  playerNodes keys: \(dict.keys.sorted())")
        }
    }
    
    // Modify only one player's state node
    print("\n✏️  Modifying playerNodes[\(playerID.rawValue)]...")
    if var playerNode = state.playerNodes[playerID] {
        playerNode.hpCurrent = 90
        playerNode.lastAction = "attacked"
        state.playerNodes[playerID] = playerNode
    }
    
    // Get dirty fields
    let dirtyFields = state.getDirtyFields()
    print("\n🏷️  Dirty Fields: \(dirtyFields)")
    
    // Generate snapshot with dirty tracking
    let snapshotWithDirty = try! syncEngine.snapshot(for: playerID, from: state, dirtyFields: dirtyFields)
    
    print("\n📊 Snapshot with Dirty Tracking:")
    print("  Keys: \(snapshotWithDirty.values.keys.sorted())")
    if let playerNodesValue = snapshotWithDirty.values["playerNodes"] {
        print("  playerNodes type: \(type(of: playerNodesValue))")
        if case .object(let dict) = playerNodesValue {
            print("  ⚠️  playerNodes contains \(dict.count) keys")
            print("  ⚠️  playerNodes keys: \(dict.keys.sorted())")
            
            // Check if it contains only the modified player or all players
            if dict.count == 1 && dict.keys.contains(playerID.rawValue) {
                print("  ✅ GOOD: Only contains modified player key")
            } else if dict.count > 1 {
                print("  ❌ PROBLEM: Contains \(dict.count) keys, should only contain 1")
                print("  ❌ This means the entire Dictionary is being serialized")
            }
        }
    }
    
    // Generate snapshot without dirty tracking for comparison
    let snapshotWithoutDirty = try! syncEngine.snapshot(for: playerID, from: state)
    
    print("\n📊 Snapshot without Dirty Tracking (for comparison):")
    print("  Keys: \(snapshotWithoutDirty.values.keys.sorted())")
    if let playerNodesValue = snapshotWithoutDirty.values["playerNodes"] {
        if case .object(let dict) = playerNodesValue {
            print("  playerNodes contains \(dict.count) keys")
        }
    }
    
    print("\n" + String(repeating: "=", count: 60))
}

