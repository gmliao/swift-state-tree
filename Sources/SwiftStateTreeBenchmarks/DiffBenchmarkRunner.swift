// Sources/SwiftStateTreeBenchmarks/DiffBenchmarkRunner.swift

import Foundation
import SwiftStateTree

/// Benchmark runner that compares standard diff vs optimized diff performance
/// 
/// Compares:
/// - Standard diff (useDirtyTracking=false): Compares full snapshots to detect changes
/// - Optimized diff (useDirtyTracking=true): Uses dirty tracking to only check changed fields
/// 
/// Environment variable control:
/// - DIFF_BENCHMARK_MODE=standard: Only run standard diff (no dirty tracking)
/// - DIFF_BENCHMARK_MODE=optimized: Only run optimized diff (with dirty tracking)
/// - DIFF_BENCHMARK_MODE=both: Run both and compare (default)
struct DiffBenchmarkRunner: BenchmarkRunner {
    typealias Mode = BenchmarkEnvConfig.DiffBenchmarkMode

    static var currentMode: Mode {
        BenchmarkEnvConfig.fromEnvironment().diffBenchmarkMode
    }
    
    mutating func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        let mode = Self.currentMode
        let iterations = 100  // Use fixed iterations for diff comparison (warmup + measurement)
        
        // Update description to reflect actual iterations
        let actualConfig = BenchmarkConfig(
            name: config.name,
            playerCount: config.playerCount,
            cardsPerPlayer: config.cardsPerPlayer,
            iterations: iterations
        )
        
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
        
        var standardTimes: [TimeInterval] = []
        var optimizedTimes: [TimeInterval] = []
        
        // Run standard diff benchmark if needed
        if mode == .both || mode == .standard {
            print("  Warming up (standard diff)...", terminator: "")
            var standardSyncEngine = SyncEngine()
            // Establish baseline (first sync)
            _ = try? standardSyncEngine.generateDiff(for: playerID, from: state)
            print(" ✓")
            
            print("  Running \(iterations) iterations for standard diff (no dirty tracking)...", terminator: "")
            // For each iteration, create a fresh modified state to test diff generation
            for i in 0..<iterations {
                var iterState = state
                iterState.round = 2 + i  // Change round to ensure diff is generated
                
                if var playerNode = iterState.playerNodes[playerID] {
                    playerNode.hpCurrent = 90 - i  // Change hpCurrent
                    playerNode.lastAction = "attacked_\(i)"  // Change lastAction
                    iterState.playerNodes[playerID] = playerNode
                }
                
                let time = try! measureTime {
                    _ = try standardSyncEngine.generateDiff(for: playerID, from: iterState, useDirtyTracking: false)
                }
                standardTimes.append(time)
                
                if (i + 1) % 10 == 0 {
                    print(".", terminator: "")
                }
            }
            print(" ✓")
        }
        
        // Run optimized diff benchmark if needed
        if mode == .both || mode == .optimized {
            print("  Warming up (optimized diff)...", terminator: "")
            var optimizedSyncEngine = SyncEngine()
            // Establish baseline (first sync)
            _ = try? optimizedSyncEngine.generateDiff(for: playerID, from: state)
            print(" ✓")
            
            print("  Running \(iterations) iterations for optimized diff (with dirty tracking)...", terminator: "")
            // For each iteration, create a fresh modified state with dirty flags set
            for i in 0..<iterations {
                var iterState = state
                iterState.round = 2 + i  // Change round (automatically marked as dirty)
                
                if var playerNode = iterState.playerNodes[playerID] {
                    playerNode.hpCurrent = 90 - i  // Change hpCurrent (automatically marked as dirty)
                    playerNode.lastAction = "attacked_\(i)"  // Change lastAction (automatically marked as dirty)
                    iterState.playerNodes[playerID] = playerNode
                }
                
                let time = try! measureTime {
                    _ = try optimizedSyncEngine.generateDiff(for: playerID, from: iterState, useDirtyTracking: true)
                }
                optimizedTimes.append(time)
                
                if (i + 1) % 10 == 0 {
                    print(".", terminator: "")
                }
            }
            print(" ✓")
        }
        
        // Get snapshot size for result (using modified state)
        let sizeSyncEngine = SyncEngine()
        let snapshot = try! sizeSyncEngine.snapshot(for: playerID, from: modifiedState)
        let snapshotSize = estimateSnapshotSize(snapshot)
        
        // Handle results based on mode
        switch mode {
        case .standard:
            let standardAverage = standardTimes.reduce(0, +) / Double(standardTimes.count)
            print("\n  📊 Standard Diff Results:")
            print("    ⏱️  Average time: \(String(format: "%.3f", standardAverage * 1000))ms")
            print("    ⏱️  Min time: \(String(format: "%.3f", (standardTimes.min() ?? 0) * 1000))ms")
            print("    ⏱️  Max time: \(String(format: "%.3f", (standardTimes.max() ?? 0) * 1000))ms")
            
            return BenchmarkResult(
                config: actualConfig,
                averageTime: standardAverage,
                minTime: standardTimes.min() ?? 0,
                maxTime: standardTimes.max() ?? 0,
                snapshotSize: snapshotSize,
                throughput: 1.0 / standardAverage,
                executionMode: "Diff Generation (Standard, \(iterations) iterations)",
                bytesPerPlayer: nil
            )
            
        case .optimized:
            let optimizedAverage = optimizedTimes.reduce(0, +) / Double(optimizedTimes.count)
            print("\n  📊 Optimized Diff Results:")
            print("    ⏱️  Average time: \(String(format: "%.3f", optimizedAverage * 1000))ms")
            print("    ⏱️  Min time: \(String(format: "%.3f", (optimizedTimes.min() ?? 0) * 1000))ms")
            print("    ⏱️  Max time: \(String(format: "%.3f", (optimizedTimes.max() ?? 0) * 1000))ms")
            
            return BenchmarkResult(
                config: actualConfig,
                averageTime: optimizedAverage,
                minTime: optimizedTimes.min() ?? 0,
                maxTime: optimizedTimes.max() ?? 0,
                snapshotSize: snapshotSize,
                throughput: 1.0 / optimizedAverage,
                executionMode: "Diff Generation (Optimized, \(iterations) iterations)",
                bytesPerPlayer: nil
            )
            
        case .both:
            // Calculate averages and comparison
            let standardAverage = standardTimes.reduce(0, +) / Double(standardTimes.count)
            let optimizedAverage = optimizedTimes.reduce(0, +) / Double(optimizedTimes.count)
            let speedup = standardAverage / optimizedAverage
            let timeImprovement = (standardAverage - optimizedAverage) / standardAverage * 100
            
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
                config: actualConfig,
                averageTime: optimizedAverage,
                minTime: optimizedTimes.min() ?? 0,
                maxTime: optimizedTimes.max() ?? 0,
                snapshotSize: snapshotSize,
                throughput: 1.0 / optimizedAverage,
                executionMode: "Diff Generation (Optimized, \(iterations) iterations)",
                bytesPerPlayer: nil
            )
        }
    }
}

