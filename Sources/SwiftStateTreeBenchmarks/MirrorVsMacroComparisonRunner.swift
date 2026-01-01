// Sources/SwiftStateTreeBenchmarks/MirrorVsMacroComparisonRunner.swift

import Foundation
import SwiftStateTree

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
    
    mutating func run(
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

