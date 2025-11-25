// Sources/SwiftStateTreeBenchmarks/BenchmarkSuite.swift

import Foundation
import SwiftStateTree

/// Benchmark suite that can run different types of benchmarks
struct BenchmarkSuite: @unchecked Sendable {
    let name: String
    let runner: any BenchmarkRunner
    let configurations: [BenchmarkConfig]
    
    nonisolated func run() async -> [BenchmarkResult] {
        printBox(title: name)
        
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
    
    /// Print a box with title (fixed width to prevent layout issues)
    private func printBox(title: String) {
        let boxWidth = 63
        let titleWidth = title.count
        let padding = max(0, boxWidth - titleWidth - 2)
        let leftPadding = padding / 2
        let rightPadding = padding - leftPadding
        
        print("")
        print("╔" + String(repeating: "═", count: boxWidth) + "╗")
        print("║" + String(repeating: " ", count: leftPadding) + title + String(repeating: " ", count: rightPadding) + "║")
        print("╚" + String(repeating: "═", count: boxWidth) + "╝")
        print("")
    }
}

