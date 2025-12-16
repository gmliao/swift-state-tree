// Sources/SwiftStateTreeBenchmarks/BenchmarkSuiteConfig.swift

import Foundation
import SwiftStateTree

/// Available benchmark suite types
enum BenchmarkSuiteType: String, CaseIterable {
    case singleThreaded = "single"
    case diff = "diff"
    case mirrorVsMacro = "mirror"
    case transportAdapterSync = "transport-sync"
    case all = "all"
    
    var displayName: String {
        switch self {
        case .singleThreaded: return "Single-threaded Execution"
        case .diff: return "Standard vs Optimized Diff Comparison"
        case .mirrorVsMacro: return "Mirror vs Macro Performance Comparison"
        case .transportAdapterSync: return "TransportAdapter Sync Performance"
        case .all: return "All Suites"
        }
    }
    
    var description: String {
        switch self {
        case .singleThreaded: return "Sequential execution on main thread"
        case .diff: return "Compare standard diff vs optimized diff (with dirty tracking) performance"
        case .mirrorVsMacro: return "Compare Mirror-based vs Macro-generated code"
        case .transportAdapterSync: return "TransportAdapter sync performance benchmark"
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
                type: .diff,
                name: "Standard vs Optimized Diff Comparison",
                runner: DiffBenchmarkRunner(),
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
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Serial vs Parallel Sync",
                runner: TransportAdapterSyncBenchmarkRunner(playerCounts: [10, 50, 100, 200]),
                configurations: [
                    BenchmarkConfigurations.standard[1],  // Small State
                    BenchmarkConfigurations.standard[2]   // Medium State
                ]
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

