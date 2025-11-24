// Sources/SwiftStateTreeBenchmarks/BenchmarkRunner.swift

import Foundation
import SwiftStateTree

// MARK: - Timing Utilities

/// Helper to measure execution time
func measureTime(_ block: () throws -> Void) rethrows -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    try block()
    return CFAbsoluteTimeGetCurrent() - start
}

/// Estimate snapshot size (rough calculation)
func estimateSnapshotSize(_ snapshot: StateSnapshot) -> Int {
    var size = 0
    for (key, value) in snapshot.values {
        size += key.utf8.count
        size += estimateValueSize(value)
    }
    return size
}

func estimateValueSize(_ value: SnapshotValue) -> Int {
    switch value {
    case .null: return 4
    case .bool: return 1
    case .int: return 8
    case .double: return 8
    case .string(let s): return s.utf8.count
    case .array(let arr): return arr.reduce(0) { $0 + estimateValueSize($1) }
    case .object(let obj): return obj.reduce(0) { $0 + $1.key.utf8.count + estimateValueSize($1.value) }
    }
}

/// Estimate the size of a SnapshotValue in bytes (for patch size calculation)
func estimateSnapshotValueSize(_ value: SnapshotValue) -> Int {
    return estimateValueSize(value)
}

// MARK: - Benchmark Runner Protocol

/// Protocol for different benchmark execution strategies
protocol BenchmarkRunner {
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult
}

// MARK: - Single-threaded Runner

/// Single-threaded benchmark runner
/// 
/// **Execution Model**: Sequential execution on main thread
/// - All iterations run sequentially
/// - No concurrent operations
/// - Results are deterministic and reproducible
struct SingleThreadedRunner: BenchmarkRunner {
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        let syncEngine = SyncEngine()
        var times: [TimeInterval] = []
        var snapshotSize: Int = 0
        
        print("  Warming up...", terminator: "")
        // Warmup run (discard first result)
        _ = try? syncEngine.snapshot(for: playerID, from: state)
        print(" ✓")
        
        print("  Running \(config.iterations) iterations...", terminator: "")
        // Actual benchmark runs - executed sequentially
        for i in 0..<config.iterations {
            let time = try! measureTime {
                let snapshot = try syncEngine.snapshot(for: playerID, from: state)
                if i == 0 {
                    snapshotSize = estimateSnapshotSize(snapshot)
                }
            }
            times.append(time)
            
            if (i + 1) % 10 == 0 {
                print(".", terminator: "")
            }
        }
        print(" ✓")
        
        let average = times.reduce(0, +) / Double(times.count)
        let min = times.min() ?? 0
        let max = times.max() ?? 0
        let throughput = 1.0 / average
        
        return BenchmarkResult(
            config: config,
            averageTime: average,
            minTime: min,
            maxTime: max,
            snapshotSize: snapshotSize,
            throughput: throughput,
            executionMode: "Single-threaded"
        )
    }
}

// MARK: - Parallel Runner

/// Parallel benchmark runner using multiple threads
/// 
/// **Execution Model**: Concurrent execution across multiple cores
/// - Uses TaskGroup to parallelize snapshot generation
/// - Each iteration runs concurrently
/// - Measures total wall-clock time for all iterations
struct ParallelRunner: BenchmarkRunner {
    let coreCount: Int
    
    init(coreCount: Int? = nil) {
        self.coreCount = coreCount ?? ProcessInfo.processInfo.processorCount
    }
    
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        let syncEngine = SyncEngine()
        
        print("  Warming up...", terminator: "")
        // Warmup run and get snapshot size
        let warmupSnapshot = try? syncEngine.snapshot(for: playerID, from: state)
        let snapshotSize = warmupSnapshot.map(estimateSnapshotSize) ?? 0
        print(" ✓")
        
        print("  Running \(config.iterations) iterations in parallel (using \(coreCount) cores)...", terminator: "")
        
        // Measure total time for all parallel iterations
        let totalStart = CFAbsoluteTimeGetCurrent()
        
        // Run all iterations in parallel
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<config.iterations {
                group.addTask {
                    _ = try? syncEngine.snapshot(for: playerID, from: state)
                }
            }
            
            // Wait for all tasks to complete
            var completed = 0
            for await _ in group {
                completed += 1
                if completed % 10 == 0 {
                    print(".", terminator: "")
                }
            }
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - totalStart
        print(" ✓")
        
        // Calculate metrics
        let averageTime = totalTime / Double(config.iterations)
        let throughput = Double(config.iterations) / totalTime
        
        return BenchmarkResult(
            config: config,
            averageTime: averageTime,
            minTime: averageTime,  // Parallel execution doesn't track individual times
            maxTime: averageTime,
            snapshotSize: snapshotSize,
            throughput: throughput,
            executionMode: "Parallel (\(coreCount) cores)"
        )
    }
}

// MARK: - Multi-Player Parallel Runner

/// Parallel runner that generates snapshots for multiple players simultaneously
/// 
/// This simulates a real-world scenario where the server needs to generate
/// snapshots for multiple players at the same time.
struct MultiPlayerParallelRunner: BenchmarkRunner {
    let playerCount: Int
    let coreCount: Int
    
    init(playerCount: Int, coreCount: Int? = nil) {
        self.playerCount = playerCount
        self.coreCount = coreCount ?? ProcessInfo.processInfo.processorCount
    }
    
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        let syncEngine = SyncEngine()
        
        print("  Warming up...", terminator: "")
        // Get snapshot size from warmup
        let warmupSnapshot = try? syncEngine.snapshot(for: playerID, from: state)
        let snapshotSize = warmupSnapshot.map(estimateSnapshotSize) ?? 0
        print(" ✓")
        
        print("  Generating snapshots for \(playerCount) players in parallel (using \(coreCount) cores)...", terminator: "")
        
        // Generate player IDs
        let playerIDs = (0..<playerCount).map { PlayerID("player_\($0)") }
        
        let totalStart = CFAbsoluteTimeGetCurrent()
        
        // Run multiple iterations, each generating snapshots for all players in parallel
        for iteration in 0..<config.iterations {
            await withTaskGroup(of: Void.self) { group in
                for playerID in playerIDs {
                    group.addTask {
                        _ = try? syncEngine.snapshot(for: playerID, from: state)
                    }
                }
                
                // Wait for all players' snapshots
                var completed = 0
                for await _ in group {
                    completed += 1
                }
            }
            
            if (iteration + 1) % 5 == 0 {
                print(".", terminator: "")
            }
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - totalStart
        print(" ✓")
        
        let totalSnapshots = playerCount * config.iterations
        let averageTime = totalTime / Double(totalSnapshots)
        let throughput = Double(totalSnapshots) / totalTime
        
        return BenchmarkResult(
            config: config,
            averageTime: averageTime,
            minTime: averageTime,
            maxTime: averageTime,
            snapshotSize: snapshotSize,
            throughput: throughput,
            executionMode: "Multi-player Parallel (\(playerCount) players, \(coreCount) cores)"
        )
    }
}

// MARK: - Diff Benchmark Runner

/// Benchmark runner that compares snapshot vs diff generation performance
/// Also compares standard diff (useDirtyTracking=false) vs optimized diff (useDirtyTracking=true)
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
        var modifiedState = state
        modifiedState.round = 2
        if var player = modifiedState.players[playerID] {
            player.hpCurrent = 90
            modifiedState.players[playerID] = player
        }
        
        // Estimate diff size BEFORE benchmark (cache still has original state)
        // Create a fresh sync engine to get accurate diff size
        var sizeSyncEngine = SyncEngine()
        _ = try? sizeSyncEngine.generateDiff(for: playerID, from: state) // Populate cache with original state
        let diffUpdate = try! sizeSyncEngine.generateDiff(for: playerID, from: modifiedState)
        var diffSize = 0
        if case .diff(let patches) = diffUpdate {
            // Calculate actual patch size
            for patch in patches {
                diffSize += patch.path.utf8.count
                switch patch.operation {
                case .set(let value):
                    diffSize += estimateSnapshotValueSize(value)
                case .delete:
                    diffSize += 6 // "delete" keyword
                case .add(let value):
                    diffSize += 3 // "add" keyword
                    diffSize += estimateSnapshotValueSize(value)
                }
            }
        } else if case .noChange = diffUpdate {
            // No changes detected
            diffSize = 0
        }
        
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
            
            // Mark as dirty before generating diff
            optimizedState.round = 2
            if var player = optimizedState.players[playerID] {
                player.hpCurrent = 90
                optimizedState.players[playerID] = player
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
        print("  📦 Size Comparison:")
        print("    Diff size: ~\(diffSize) bytes vs Snapshot size: ~\(snapshotSize) bytes")
        print("    Size reduction: \(String(format: "%.1f", Double(snapshotSize - diffSize) / Double(snapshotSize) * 100))%")
        
        // Return result using optimized diff (as it's the recommended approach)
        return BenchmarkResult(
            config: config,
            averageTime: optimizedAverage,
            minTime: optimizedTimes.min() ?? 0,
            maxTime: optimizedTimes.max() ?? 0,
            snapshotSize: diffSize,
            throughput: 1.0 / optimizedAverage,
            executionMode: "Diff Generation (Optimized, \(iterations) iterations)"
        )
    }
}

// MARK: - Mirror vs Macro Comparison Runner

/// Benchmark runner that compares Mirror-based vs Macro-generated broadcast field extraction
///
/// This runner measures the performance difference between:
/// - **Mirror Version**: Uses runtime reflection (Mirror) to extract broadcast fields
/// - **Macro Version**: Uses compile-time generated code to extract broadcast fields
///
/// **Expected Result**: Macro version should be significantly faster due to:
/// - No runtime reflection overhead
/// - Direct field access (compiler-optimized)
/// - Type-safe compile-time code generation
struct MirrorVsMacroComparisonRunner: BenchmarkRunner {
    let iterations: Int
    
    init(iterations: Int = 1000) {
        self.iterations = iterations
    }
    
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        let syncEngine = SyncEngine()
        
        print("  Warming up both versions...", terminator: "")
        // Warmup both versions
        _ = try? syncEngine.extractBroadcastSnapshotMirrorVersion(from: state)
        _ = try? syncEngine.snapshot(for: nil, from: state)  // nil = broadcast only (uses macro version)
        print(" ✓")
        
        // Benchmark Mirror version
        print("  Running \(iterations) iterations for Mirror version...", terminator: "")
        var mirrorTimes: [TimeInterval] = []
        for i in 0..<iterations {
            let time = try! measureTime {
                _ = try syncEngine.extractBroadcastSnapshotMirrorVersion(from: state)
            }
            mirrorTimes.append(time)
            
            if (i + 1) % 100 == 0 {
                print(".", terminator: "")
            }
        }
        print(" ✓")
        
        // Benchmark Macro version
        print("  Running \(iterations) iterations for Macro version...", terminator: "")
        var macroTimes: [TimeInterval] = []
        for i in 0..<iterations {
            let time = try! measureTime {
                _ = try syncEngine.snapshot(for: nil, from: state)  // nil = broadcast only
            }
            macroTimes.append(time)
            
            if (i + 1) % 100 == 0 {
                print(".", terminator: "")
            }
        }
        print(" ✓")
        
        // Calculate statistics
        let mirrorAverage = mirrorTimes.reduce(0, +) / Double(mirrorTimes.count)
        let macroAverage = macroTimes.reduce(0, +) / Double(macroTimes.count)
        let speedup = mirrorAverage / macroAverage
        
        // Get snapshot size (same for both versions)
        let snapshot = try! syncEngine.snapshot(for: nil, from: state)
        let snapshotSize = estimateSnapshotSize(snapshot)
        
        // Print comparison
        print("\n  📊 Performance Comparison:")
        print("    Mirror Version:  \(String(format: "%.6f", mirrorAverage * 1000)) ms/op")
        print("    Macro Version:   \(String(format: "%.6f", macroAverage * 1000)) ms/op")
        print("    Speedup:         \(String(format: "%.2fx", speedup)) faster")
        print("    Improvement:     \(String(format: "%.1f", (1.0 - macroAverage / mirrorAverage) * 100))%")
        
        // Return macro version result (the optimized one)
        return BenchmarkResult(
            config: config,
            averageTime: macroAverage,
            minTime: macroTimes.min() ?? 0,
            maxTime: macroTimes.max() ?? 0,
            snapshotSize: snapshotSize,
            throughput: 1.0 / macroAverage,
            executionMode: "Macro Version (vs Mirror: \(String(format: "%.2fx", speedup)) faster)"
        )
    }
}

