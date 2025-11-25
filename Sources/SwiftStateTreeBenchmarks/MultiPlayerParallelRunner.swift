// Sources/SwiftStateTreeBenchmarks/MultiPlayerParallelRunner.swift

import Foundation
import SwiftStateTree

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

