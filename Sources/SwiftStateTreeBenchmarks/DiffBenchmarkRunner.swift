// Sources/SwiftStateTreeBenchmarks/DiffBenchmarkRunner.swift

import Foundation
import SwiftStateTree

/// Benchmark runner that compares standard diff vs optimized diff performance
/// 
/// Compares:
/// - Standard diff (useDirtyTracking=false): Compares full snapshots to detect changes
/// - Optimized diff (useDirtyTracking=true): Uses dirty tracking to only check changed fields
struct DiffBenchmarkRunner: BenchmarkRunner {
    let iterations: Int
    
    init(iterations: Int = 100) {
        self.iterations = iterations
    }
    
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        // Create a modified state for diff calculation
        // Simulate real game scenario: only modify a few fields per operation
        var modifiedState = state
        modifiedState.round = 2  // Only modify round
        
        // Only modify one player's state node (simulate player action)
        if var playerNode = modifiedState.playerNodes[playerID] {
            playerNode.hpCurrent = 90  // Player took damage
            playerNode.lastAction = "attacked"  // Update action
            modifiedState.playerNodes[playerID] = playerNode
        }
        
        // This simulates a typical game operation: only 2-3 fields changed
        // Dirty tracking can skip checking the other ~15+ fields
        
        // Benchmark standard diff (useDirtyTracking = false)
        print("  Warming up (standard diff)...", terminator: "")
        var standardSyncEngine = SyncEngine()
        _ = try? standardSyncEngine.generateDiff(for: playerID, from: state)
        print(" ✓")
        
        print("  Running \(iterations) iterations for standard diff (no dirty tracking)...", terminator: "")
        var standardTimes: [TimeInterval] = []
        for i in 0..<iterations {
            // Reset cache for each iteration to get consistent results
            if i > 0 {
                standardSyncEngine = SyncEngine()
                _ = try? standardSyncEngine.generateDiff(for: playerID, from: state)
            }
            
            let time = try! measureTime {
                _ = try standardSyncEngine.generateDiff(for: playerID, from: modifiedState, useDirtyTracking: false)
            }
            standardTimes.append(time)
            
            if (i + 1) % 10 == 0 {
                print(".", terminator: "")
            }
        }
        print(" ✓")
        
        // Benchmark optimized diff (useDirtyTracking = true)
        print("  Warming up (optimized diff)...", terminator: "")
        var optimizedSyncEngine = SyncEngine()
        _ = try? optimizedSyncEngine.generateDiff(for: playerID, from: state)
        var optimizedState = modifiedState
        optimizedState.clearDirty() // Clear dirty state before benchmark
        print(" ✓")
        
        print("  Running \(iterations) iterations for optimized diff (with dirty tracking)...", terminator: "")
        var optimizedTimes: [TimeInterval] = []
        for i in 0..<iterations {
            // Reset cache and state for each iteration to get consistent results
            if i > 0 {
                optimizedSyncEngine = SyncEngine()
                _ = try? optimizedSyncEngine.generateDiff(for: playerID, from: state)
                optimizedState = modifiedState
                optimizedState.clearDirty()
            }
            
            // Mark as dirty before generating diff (same modifications as standard diff)
            optimizedState.round = 2
            
            if var playerNode = optimizedState.playerNodes[playerID] {
                playerNode.hpCurrent = 90
                playerNode.lastAction = "attacked"
                optimizedState.playerNodes[playerID] = playerNode
            }
            
            let time = try! measureTime {
                _ = try optimizedSyncEngine.generateDiff(for: playerID, from: optimizedState, useDirtyTracking: true)
            }
            optimizedTimes.append(time)
            
            if (i + 1) % 10 == 0 {
                print(".", terminator: "")
            }
        }
        print(" ✓")
        
        // Calculate averages
        let standardAverage = standardTimes.reduce(0, +) / Double(standardTimes.count)
        let optimizedAverage = optimizedTimes.reduce(0, +) / Double(optimizedTimes.count)
        let speedup = standardAverage / optimizedAverage
        let timeImprovement = (standardAverage - optimizedAverage) / standardAverage * 100
        
        // Get snapshot size for result (using modified state)
        let sizeSyncEngine = SyncEngine()
        let snapshot = try! sizeSyncEngine.snapshot(for: playerID, from: modifiedState)
        let snapshotSize = estimateSnapshotSize(snapshot)
        
        // Print comparison results
        print("\n  📊 Performance Comparison:")
        print("    Standard diff (no dirty tracking):")
        print("      ⏱️  Average time: \(String(format: "%.3f", standardAverage * 1000))ms")
        print("    Optimized diff (with dirty tracking):")
        print("      ⏱️  Average time: \(String(format: "%.3f", optimizedAverage * 1000))ms")
        print("    🚀 Speedup: \(String(format: "%.2f", speedup))x")
        print("    ⚡ Time improvement: \(String(format: "%.1f", timeImprovement))%")
        
        // Return result using optimized diff (as it's the recommended approach)
        return BenchmarkResult(
            config: config,
            averageTime: optimizedAverage,
            minTime: optimizedTimes.min() ?? 0,
            maxTime: optimizedTimes.max() ?? 0,
            snapshotSize: snapshotSize,
            throughput: 1.0 / optimizedAverage,
            executionMode: "Diff Generation (Optimized, \(iterations) iterations)"
        )
    }
}

