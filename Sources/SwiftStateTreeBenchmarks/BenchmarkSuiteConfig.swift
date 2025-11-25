// Sources/SwiftStateTreeBenchmarks/BenchmarkSuiteConfig.swift

import Foundation
import SwiftStateTree

/// Available benchmark suite types
enum BenchmarkSuiteType: String, CaseIterable {
    case singleThreaded = "single"
    case parallel = "parallel"
    case multiPlayer = "multiplayer"
    case diff = "diff"
    case mirrorVsMacro = "mirror"
    case all = "all"
    
    var displayName: String {
        switch self {
        case .singleThreaded: return "Single-threaded Execution"
        case .parallel: return "Parallel Execution"
        case .multiPlayer: return "Multi-player Parallel Execution"
        case .diff: return "Standard vs Optimized Diff Comparison"
        case .mirrorVsMacro: return "Mirror vs Macro Performance Comparison"
        case .all: return "All Suites"
        }
    }
    
    var description: String {
        switch self {
        case .singleThreaded: return "Sequential execution on main thread"
        case .parallel: return "Concurrent execution across multiple cores"
        case .multiPlayer: return "Generate snapshots for multiple players simultaneously"
        case .diff: return "Compare standard diff vs optimized diff (with dirty tracking) performance"
        case .mirrorVsMacro: return "Compare Mirror-based vs Macro-generated code"
        case .all: return "Run all benchmark suites"
        }
    }
}

/// Configuration for a benchmark suite
struct BenchmarkSuiteConfig {
    let type: BenchmarkSuiteType
    let name: String
    let runner: any BenchmarkRunner
    let configurations: [BenchmarkConfig]
}

/// All available benchmark suite configurations
struct BenchmarkSuites {
    static func all() -> [BenchmarkSuiteConfig] {
        return [
            BenchmarkSuiteConfig(
                type: .singleThreaded,
                name: "Single-threaded Execution",
                runner: SingleThreadedRunner(),
                configurations: BenchmarkConfigurations.standard
            ),
            BenchmarkSuiteConfig(
                type: .parallel,
                name: "Parallel Execution",
                runner: ParallelRunner(),
                configurations: BenchmarkConfigurations.standard
            ),
            BenchmarkSuiteConfig(
                type: .multiPlayer,
                name: "Multi-player Parallel Execution",
                runner: MultiPlayerParallelRunner(playerCount: 10),
                configurations: [
                    BenchmarkConfigurations.standard[2],  // Medium State
                    BenchmarkConfigurations.standard[3]    // Large State
                ]
            ),
            BenchmarkSuiteConfig(
                type: .diff,
                name: "Standard vs Optimized Diff Comparison",
                runner: DiffBenchmarkRunner(iterations: 100),
                configurations: [
                    BenchmarkConfigurations.standard[0],  // Tiny State
                    BenchmarkConfigurations.standard[1],  // Small State
                    BenchmarkConfigurations.standard[2]   // Medium State
                ]
            ),
            BenchmarkSuiteConfig(
                type: .mirrorVsMacro,
                name: "Mirror vs Macro Performance Comparison",
                runner: MirrorVsMacroComparisonRunner(iterations: 1000),
                configurations: BenchmarkConfigurations.standard
            )
        ]
    }
    
    static func get(suiteType: BenchmarkSuiteType) -> [BenchmarkSuiteConfig] {
        if suiteType == .all {
            return all()
        }
        return all().filter { $0.type == suiteType }
    }
}

