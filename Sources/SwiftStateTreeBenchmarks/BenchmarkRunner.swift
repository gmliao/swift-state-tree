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

// MARK: - Benchmark Runner Protocol

/// Protocol for different benchmark execution strategies
protocol BenchmarkRunner {
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateTree,
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
        state: BenchmarkStateTree,
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
        state: BenchmarkStateTree,
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
        state: BenchmarkStateTree,
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
struct DiffBenchmarkRunner: BenchmarkRunner {
    let iterations: Int
    
    init(iterations: Int = 100) {
        self.iterations = iterations
    }
    
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateTree,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        var syncEngine = SyncEngine()
        
        print("  Warming up...", terminator: "")
        // Warmup - first sync caches
        _ = try? syncEngine.generateDiff(for: playerID, from: state)
        _ = try? syncEngine.snapshot(for: playerID, from: state)
        print(" ✓")
        
        print("  Running \(iterations) iterations for diff generation...", terminator: "")
        var diffTimes: [TimeInterval] = []
        
        // Create a modified state for diff calculation
        var modifiedState = state
        modifiedState.round = 2
        modifiedState.players[playerID]?.hpCurrent = 90
        
        // Benchmark diff generation
        for i in 0..<iterations {
            let time = try! measureTime {
                _ = try syncEngine.generateDiff(for: playerID, from: modifiedState)
            }
            diffTimes.append(time)
            
            if (i + 1) % 10 == 0 {
                print(".", terminator: "")
            }
        }
        print(" ✓")
        
        // Estimate diff size
        let diffUpdate = try! syncEngine.generateDiff(for: playerID, from: modifiedState)
        var diffSize = 0
        if case .diff(let patches) = diffUpdate {
            // Rough estimate: path + value size
            for patch in patches {
                diffSize += patch.path.utf8.count
                diffSize += 50 // Rough estimate for patch data
            }
        }
        
        let diffAverage = diffTimes.reduce(0, +) / Double(diffTimes.count)
        let snapshot = try! syncEngine.snapshot(for: playerID, from: modifiedState)
        let snapshotSize = estimateSnapshotSize(snapshot)
        
        print("  Diff size: ~\(diffSize) bytes vs Snapshot size: ~\(snapshotSize) bytes")
        print("  Size reduction: \(String(format: "%.1f", Double(snapshotSize - diffSize) / Double(snapshotSize) * 100))%")
        
        return BenchmarkResult(
            config: config,
            averageTime: diffAverage,
            minTime: diffTimes.min() ?? 0,
            maxTime: diffTimes.max() ?? 0,
            snapshotSize: diffSize,
            throughput: 1.0 / diffAverage,
            executionMode: "Diff Generation (\(iterations) iterations)"
        )
    }
}

