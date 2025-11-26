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
        print("=== Full Snapshot (for playerID) ===")
        let fullSnapshot = try state.snapshot(for: playerID, dirtyFields: nil)
        print("Full snapshot keys: \(fullSnapshot.values.keys.sorted())")
        for (key, value) in fullSnapshot.values.sorted(by: { $0.key < $1.key }) {
            print("  \(key):")
            switch value {
            case .object(let obj):
                print("    Type: object, Keys: \(obj.keys.sorted())")
                for (k, v) in obj {
                    print("      - \(k): \(v)")
                }
            case .array(let arr):
                print("    Type: array, Count: \(arr.count), Values: \(arr)")
            case .string(let str):
                print("    Type: string, Value: \(str)")
            case .int(let i):
                print("    Type: int, Value: \(i)")
            default:
                print("    Type: \(value)")
            }
        }
        
        print("\n=== Broadcast Snapshot ===")
        let broadcastSnapshot = try state.broadcastSnapshot(dirtyFields: nil)
        print("Broadcast snapshot keys: \(broadcastSnapshot.values.keys.sorted())")
        for (key, value) in broadcastSnapshot.values.sorted(by: { $0.key < $1.key }) {
            print("  \(key):")
            switch value {
            case .object(let obj):
                print("    Type: object, Keys: \(obj.keys.sorted())")
                for (k, v) in obj {
                    print("      - \(k): \(v)")
                }
            case .array(let arr):
                print("    Type: array, Count: \(arr.count)")
            case .string(let str):
                print("    Type: string, Value: \(str)")
            case .int(let i):
                print("    Type: int, Value: \(i)")
            default:
                print("    Type: \(value)")
            }
        }
        
        print("\n=== PerPlayer Snapshot (extracted) ===")
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
        print("PerPlayer snapshot keys: \(perPlayerValues.keys.sorted())")
        for (key, value) in perPlayerValues.sorted(by: { $0.key < $1.key }) {
            print("  \(key):")
            switch value {
            case .object(let obj):
                print("    Type: object, Keys: \(obj.keys.sorted())")
                for (k, v) in obj {
                    print("      - \(k): \(v)")
                }
            case .array(let arr):
                print("    Type: array, Count: \(arr.count), Values: \(arr)")
            default:
                print("    Type: \(value)")
            }
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
        print("=== First Sync ===")
        let firstStandard = try syncEngine1.generateDiff(for: playerID, from: state1, useDirtyTracking: false)
        let firstOptimized = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: true)
        print("Standard first sync: \(firstStandard)")
        print("Optimized first sync: \(firstOptimized)")
        
        // Check what's in cache by looking at first sync patches
        if case .firstSync(let standardPatches) = firstStandard {
            print("Standard first sync patches:")
            for patch in standardPatches {
                print("  - \(patch.path): \(patch.operation)")
            }
        }
        if case .firstSync(let optimizedPatches) = firstOptimized {
            print("Optimized first sync patches:")
            for patch in optimizedPatches {
                print("  - \(patch.path): \(patch.operation)")
            }
        }
        
        state1.clearDirty()
        state2.clearDirty()
        
        // Add new field
        print("\n=== Adding players[alice] = \"Alice\" ===")
        state1.players[playerID] = "Alice"
        state2.players[playerID] = "Alice"
        
        // Act
        print("\n=== Second Sync (After Addition) ===")
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
        
        // Print detailed patch information
        print("\n=== Standard Update Patches ===")
        if case .diff(let standardPatches) = standardUpdate {
            for patch in standardPatches {
                print("Path: \(patch.path)")
                switch patch.operation {
                case .set(let value):
                    print("  Operation: .set")
                    print("  Value: \(value)")
                    print("  Value type: \(type(of: value))")
                    if case .object(let obj) = value {
                        print("  Object keys: \(obj.keys.sorted())")
                        for (key, val) in obj {
                            print("    - \(key): \(val)")
                        }
                    } else if case .string(let str) = value {
                        print("  String value: \(str)")
                    }
                case .delete:
                    print("  Operation: .delete")
                case .add(let value):
                    print("  Operation: .add")
                    print("  Value: \(value)")
                }
                print("")
            }
        } else {
            print("Standard update: \(standardUpdate)")
        }
        
        print("\n=== Optimized Update Patches ===")
        if case .diff(let optimizedPatches) = optimizedUpdate {
            for patch in optimizedPatches {
                print("Path: \(patch.path)")
                switch patch.operation {
                case .set(let value):
                    print("  Operation: .set")
                    print("  Value: \(value)")
                    print("  Value type: \(type(of: value))")
                    if case .object(let obj) = value {
                        print("  Object keys: \(obj.keys.sorted())")
                        for (key, val) in obj {
                            print("    - \(key): \(val)")
                        }
                    } else if case .string(let str) = value {
                        print("  String value: \(str)")
                    }
                case .delete:
                    print("  Operation: .delete")
                case .add(let value):
                    print("  Operation: .add")
                    print("  Value: \(value)")
                }
                print("")
            }
        } else {
            print("Optimized update: \(optimizedUpdate)")
        }
        
        // Check cache state
        print("\n=== Cache State Analysis ===")
        // Note: We can't directly access cache, but we can infer from patches
        
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
        print("=== Broadcast Dictionary (players) ===")
        state.round = 1
        state.players = [:]
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        state.players[playerID] = "Alice"
        let update2 = try syncEngine.generateDiff(for: playerID, from: state)
        
        if case .diff(let patches) = update2 {
            print("Broadcast dictionary patches:")
            for patch in patches {
                if patch.path.hasPrefix("/players") {
                    print("  Path: \(patch.path)")
                    switch patch.operation {
                    case .set(let value):
                        if case .object(let obj) = value {
                            print("    Type: object, Keys: \(obj.keys.sorted())")
                            for (key, val) in obj {
                                print("      - \(key): \(val)")
                            }
                        } else if case .string(let str) = value {
                            print("    Type: string, Value: \(str)")
                        }
                    default:
                        print("    Operation: \(patch.operation)")
                    }
                }
            }
        }
        
        // Test perPlayer dictionary (hands) - Standard
        print("\n=== PerPlayer Dictionary (hands) - Standard ===")
        var syncEngine2 = SyncEngine()
        var state2 = DiffTestStateRootNode()
        state2.round = 1
        state2.hands = [:]
        _ = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: false)
        state2.clearDirty()
        
        state2.hands[playerID] = ["card1"]
        let update4 = try syncEngine2.generateDiff(for: playerID, from: state2, useDirtyTracking: false)
        
        if case .diff(let patches) = update4 {
            print("PerPlayer dictionary patches (Standard):")
            for patch in patches {
                if patch.path.hasPrefix("/hands") {
                    print("  Path: \(patch.path)")
                    switch patch.operation {
                    case .set(let value):
                        if case .object(let obj) = value {
                            print("    Type: object, Keys: \(obj.keys.sorted())")
                            for (key, val) in obj {
                                print("      - \(key): \(val)")
                            }
                        } else if case .array(let arr) = value {
                            print("    Type: array, Count: \(arr.count), Values: \(arr)")
                        }
                    default:
                        print("    Operation: \(patch.operation)")
                    }
                }
            }
        }
        
        // Test perPlayer dictionary (hands) - Optimized
        print("\n=== PerPlayer Dictionary (hands) - Optimized ===")
        var syncEngine3 = SyncEngine()
        var state3 = DiffTestStateRootNode()
        state3.round = 1
        state3.hands = [:]
        _ = try syncEngine3.generateDiff(for: playerID, from: state3, useDirtyTracking: true)
        state3.clearDirty()
        
        state3.hands[playerID] = ["card1"]
        let update5 = try syncEngine3.generateDiff(for: playerID, from: state3, useDirtyTracking: true)
        
        if case .diff(let patches) = update5 {
            print("PerPlayer dictionary patches (Optimized):")
            for patch in patches {
                if patch.path.hasPrefix("/hands") {
                    print("  Path: \(patch.path)")
                    switch patch.operation {
                    case .set(let value):
                        if case .object(let obj) = value {
                            print("    Type: object, Keys: \(obj.keys.sorted())")
                            for (key, val) in obj {
                                print("      - \(key): \(val)")
                            }
                        } else if case .array(let arr) = value {
                            print("    Type: array, Count: \(arr.count), Values: \(arr)")
                        }
                    default:
                        print("    Operation: \(patch.operation)")
                    }
                }
            }
        }
    }
}
