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
            // For DiffBenchmarkRunner, use actual iterations (100) instead of config.iterations
            let displayConfig: BenchmarkConfig
            if runner is DiffBenchmarkRunner {
                displayConfig = BenchmarkConfig(
                    name: config.name,
                    playerCount: config.playerCount,
                    cardsPerPlayer: config.cardsPerPlayer,
                    iterations: 100  // DiffBenchmarkRunner uses fixed 100 iterations
                )
            } else {
                displayConfig = config
            }

            // Custom description for TransportAdapter sync benchmarks:
            // config.playerCount 表示「基礎 state 大小」，實際測試的玩家數
            // 則由 TransportAdapterSyncBenchmarkRunner.playerCounts 控制，因此額外標註。
            let headerDescription: String
            if let syncRunner = runner as? TransportAdapterSyncBenchmarkRunner {
                let dynamicPlayers = syncRunner.playerCounts.map(String.init).joined(separator: ", ")
                let broadcastRatioLabel: String
                if syncRunner.broadcastPlayerRatio > 0.0 {
                    let percent = Int((syncRunner.broadcastPlayerRatio * 100.0).rounded())
                    broadcastRatioLabel = ", BroadcastPlayers: ~\(percent)%"
                } else {
                    broadcastRatioLabel = ""
                }
                headerDescription = "\(config.name) (Dynamic Players: [\(dynamicPlayers)], Cards/Player: \(config.cardsPerPlayer), Iterations: \(config.iterations)\(broadcastRatioLabel))"
            } else {
                headerDescription = displayConfig.description
            }
            
            print("\n[\(index + 1)/\(configurations.count)] Running: \(headerDescription)")
            print("  Generating test state...", terminator: "")
            
            let state = generateTestState(
                playerCount: config.playerCount,
                cardsPerPlayer: config.cardsPerPlayer
            )
            let playerID = PlayerID("player_0")
            
            print(" ✓")
            
            var mutableRunner = runner
            let result = await mutableRunner.run(config: config, state: state, playerID: playerID)
            
            // For TransportAdapterSyncBenchmarkRunner, collect all results from multiple player counts
            if let syncRunner = mutableRunner as? TransportAdapterSyncBenchmarkRunner {
                // Use all collected results instead of just the first one
                results.append(contentsOf: syncRunner.allCollectedResults)
            } else {
                results.append(result)
            }
            
            // For most benchmarks我們輸出詳細表格方便觀察。
            // 但對 TransportAdapter sync 壓力測試來說，runner 內部已經印出
            // 「Testing with X players... Average: Y ms」這類摘要，
            // 再印一個表格噪音比較大，所以這裡特別略過。
            if !(runner is TransportAdapterSyncBenchmarkRunner) {
                print(result.formattedOutput)
            }
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
