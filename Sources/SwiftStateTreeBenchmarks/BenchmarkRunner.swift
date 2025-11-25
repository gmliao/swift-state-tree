// Sources/SwiftStateTreeBenchmarks/BenchmarkRunner.swift

import Foundation
import SwiftStateTree

// MARK: - Benchmark Runner Protocol

/// Protocol for different benchmark execution strategies
protocol BenchmarkRunner {
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult
}
