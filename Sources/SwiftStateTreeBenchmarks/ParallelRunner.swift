// Sources/SwiftStateTreeBenchmarks/ParallelRunner.swift

import Foundation
import SwiftStateTree

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

