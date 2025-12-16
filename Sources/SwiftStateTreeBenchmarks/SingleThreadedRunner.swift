// Sources/SwiftStateTreeBenchmarks/SingleThreadedRunner.swift

import Foundation
import SwiftStateTree

/// Single-threaded benchmark runner
///
/// **Execution Model**: Sequential execution on main thread
/// - All iterations run sequentially
/// - No concurrent operations
/// - Results are deterministic and reproducible
///
/// NOTE: This benchmark tests snapshot generation performance in isolation.
/// It uses `syncEngine.snapshot()` which generates a full snapshot (broadcast + per-player).
/// In actual TransportAdapter.syncNow(), snapshots are extracted separately:
/// - `extractBroadcastSnapshot()` once (shared)
/// - `extractPerPlayerSnapshot()` per player
/// This benchmark provides baseline snapshot generation performance but does not
/// reflect the complete sync workflow used in production.
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

