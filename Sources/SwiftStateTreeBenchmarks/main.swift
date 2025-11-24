// Sources/SwiftStateTreeBenchmarks/main.swift

import Foundation
import SwiftStateTree

// MARK: - Benchmark Suite

/// Benchmark suite that can run different types of benchmarks
struct BenchmarkSuite {
    let name: String
    let runner: any BenchmarkRunner
    let configurations: [BenchmarkConfig]
    
    func run() async -> [BenchmarkResult] {
        print("""
        ╔═══════════════════════════════════════════════════════════════════╗
        ║                    \(name.padding(toLength: 55, withPad: " ", startingAt: 0)) ║
        ╚═══════════════════════════════════════════════════════════════════╝
        
        """)
        
        var results: [BenchmarkResult] = []
        
        for (index, config) in configurations.enumerated() {
            print("\n[\(index + 1)/\(configurations.count)] Running: \(config.description)")
            print("  Generating test state...", terminator: "")
            
            let state = generateTestState(
                playerCount: config.playerCount,
                cardsPerPlayer: config.cardsPerPlayer
            )
            let playerID = PlayerID("player_0")
            
            print(" ✓")
            
            let result = await runner.run(config: config, state: state, playerID: playerID)
            results.append(result)
            
            print(result.formattedOutput)
        }
        
        return results
    }
}

// MARK: - Main

@MainActor
func main() async {
    print("""
    ╔═══════════════════════════════════════════════════════════════════╗
    ║         SwiftStateTree Snapshot Generation Benchmark            ║
    ╚═══════════════════════════════════════════════════════════════════╝
    
    """)
    
    var allResults: [BenchmarkResult] = []
    
    // Run single-threaded benchmarks
    let singleThreadedSuite = BenchmarkSuite(
        name: "Single-threaded Execution",
        runner: SingleThreadedRunner(),
        configurations: BenchmarkConfigurations.standard
    )
    allResults.append(contentsOf: await singleThreadedSuite.run())
    
    // Run parallel benchmarks
    let parallelSuite = BenchmarkSuite(
        name: "Parallel Execution",
        runner: ParallelRunner(),
        configurations: BenchmarkConfigurations.standard
    )
    allResults.append(contentsOf: await parallelSuite.run())
    
    // Run multi-player parallel benchmarks (using medium state config)
    let multiPlayerConfigs = [
        BenchmarkConfigurations.standard[2],  // Medium State
        BenchmarkConfigurations.standard[3]    // Large State
    ]
    let multiPlayerSuite = BenchmarkSuite(
        name: "Multi-player Parallel Execution",
        runner: MultiPlayerParallelRunner(playerCount: 10),
        configurations: multiPlayerConfigs
    )
    allResults.append(contentsOf: await multiPlayerSuite.run())
    
    // Run diff vs snapshot comparison benchmarks
    let diffConfigs = [
        BenchmarkConfigurations.standard[0],  // Tiny State
        BenchmarkConfigurations.standard[1],  // Small State
        BenchmarkConfigurations.standard[2]   // Medium State
    ]
    let diffSuite = BenchmarkSuite(
        name: "Diff vs Snapshot Comparison",
        runner: DiffBenchmarkRunner(iterations: 100),
        configurations: diffConfigs
    )
    allResults.append(contentsOf: await diffSuite.run())
    
    // Run Mirror vs Macro comparison benchmarks
    let mirrorVsMacroConfigs = [
        BenchmarkConfigurations.standard[0],  // Tiny State
        BenchmarkConfigurations.standard[1],  // Small State
        BenchmarkConfigurations.standard[2],  // Medium State
        BenchmarkConfigurations.standard[3]   // Large State
    ]
    let mirrorVsMacroSuite = BenchmarkSuite(
        name: "Mirror vs Macro Performance Comparison",
        runner: MirrorVsMacroComparisonRunner(iterations: 1000),
        configurations: mirrorVsMacroConfigs
    )
    allResults.append(contentsOf: await mirrorVsMacroSuite.run())
    
    // Summary
    print("\n" + String(repeating: "═", count: 65))
    print("SUMMARY")
    print(String(repeating: "═", count: 65))
    
    // Compare single-threaded vs parallel
    print("\n📊 Performance Comparison:")
    print(String(repeating: "-", count: 65))
    
    let singleThreadedResults = allResults.filter { $0.executionMode == "Single-threaded" }
    let parallelResults = allResults.filter { $0.executionMode.contains("Parallel") && !$0.executionMode.contains("Multi-player") }
    
    if singleThreadedResults.count == parallelResults.count {
        print("\nSingle-threaded vs Parallel Throughput:")
        for i in 0..<singleThreadedResults.count {
            let single = singleThreadedResults[i]
            let parallel = parallelResults[i]
            let speedup = parallel.throughput / single.throughput
            let coreCount = ProcessInfo.processInfo.processorCount
            let efficiency = (speedup / Double(coreCount)) * 100
            
            print("  \(single.config.name):")
            print("    Single-threaded: \(String(format: "%.2f", single.throughput)) snapshots/sec")
            print("    Parallel:        \(String(format: "%.2f", parallel.throughput)) snapshots/sec")
            print("    Speedup:         \(String(format: "%.2fx", speedup)) (theoretical: \(coreCount)x)")
            print("    Efficiency:      \(String(format: "%.1f", efficiency))%")
        }
    }
    
    // CSV Output
    print("\n📄 CSV Output (for analysis):")
    print(String(repeating: "-", count: 65))
    print("Name,Players,Cards/Player,Iterations,ExecutionMode,AvgTime(ms),MinTime(ms),MaxTime(ms),Throughput(snapshots/sec),Size(bytes)")
    for result in allResults {
        print(result.csvRow)
    }
    
    print("\n" + String(repeating: "═", count: 65))
    print("Benchmark completed!")
    print(String(repeating: "═", count: 65))
}

// Run main function
Task { @MainActor in
    await main()
    exit(0)
}
RunLoop.main.run()
