// Sources/SwiftStateTreeBenchmarks/BenchmarkSuiteConfig.swift

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Available benchmark suite types
enum BenchmarkSuiteType: String, CaseIterable {
    case singleThreaded = "single"
    case diff = "diff"
    case parallelDiff = "parallel-diff"
    case parallelEncode = "parallel-encode"
    case mirrorVsMacro = "mirror"
    case transportAdapterSync = "transport-sync"
    case transportAdapterSyncPlayers = "transport-sync-players"
    case all = "all"
    
    var displayName: String {
        switch self {
        case .singleThreaded: return "Single-threaded Execution"
        case .diff: return "Standard vs Optimized Diff Comparison"
        case .parallelDiff: return "Parallel Diff Experiment"
        case .parallelEncode: return "Parallel Encode Experiment"
        case .mirrorVsMacro: return "Mirror vs Macro Performance Comparison"
        case .transportAdapterSync: return "TransportAdapter Sync Performance"
        case .transportAdapterSyncPlayers: return "TransportAdapter Sync Performance (Broadcast Players)"
        case .all: return "All Suites"
        }
    }
    
    var description: String {
        switch self {
        case .singleThreaded: return "Sequential execution on main thread"
        case .diff: return "Compare standard diff vs optimized diff (with dirty tracking) performance"
        case .parallelDiff: return "Compare serial vs TaskGroup diff for multi-player sync"
        case .parallelEncode: return "Compare serial vs TaskGroup JSON encoding for per-player updates"
        case .mirrorVsMacro: return "Compare Mirror-based vs Macro-generated code"
        case .transportAdapterSync: return "TransportAdapter sync performance benchmark"
        case .transportAdapterSyncPlayers: return "TransportAdapter sync benchmark with broadcast players mutated each tick"
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
    static func all(
        transportDirtyTrackingOverride: Bool? = nil,
        dirtyRatioOverride: Double? = nil,
        transportEncodingOverride: TransportEncoding? = nil
    ) -> [BenchmarkSuiteConfig] {
        // If override provided, clamp to [0, 1] to避免無效值
        let clampedRatio = dirtyRatioOverride.map { max(0.0, min($0, 1.0)) }
        
        // Use override for all tiers if provided; otherwise use各自預設
        let lowRatio = clampedRatio ?? 0.05
        let mediumRatio = clampedRatio ?? 0.20
        let highRatio = clampedRatio ?? 0.80
        let transportCodec = (transportEncodingOverride ?? .messagePack).makeCodec()
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
                type: .parallelDiff,
                name: "Parallel Diff Experiment (Hands Dirty ~20%)",
                runner: ParallelDiffBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: mediumRatio,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .parallelEncode,
                name: "Parallel Encode Experiment (JSON)",
                runner: ParallelEncodeBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50]
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .mirrorVsMacro,
                name: "Mirror vs Macro Performance Comparison",
                runner: MirrorVsMacroComparisonRunner(iterations: 1000),
                configurations: BenchmarkConfigurations.standard
            ),
            // TransportAdapter Sync benchmarks with不同「玩家變更比例」預設：
            // - Low  (~5%)   : 少量玩家變更，偏靜態或慢速遊戲
            // - Medium (~20%): 一般即時遊戲（預設比例）
            // - High (~80%) : 極端壓力測試，接近所有玩家每 tick 都在變
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Sync (Low Dirty ~5%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: lowRatio,
                    transportCodec: transportCodec,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Sync (Medium Dirty ~20%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: mediumRatio,
                    transportCodec: transportCodec,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Sync (High Dirty ~80%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: highRatio,
                    transportCodec: transportCodec,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            // TransportAdapter Sync benchmarks where broadcast `players` is also mutated every tick.
            // This is closer to real gameplay where public player state changes frequently.
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportAdapter Sync (Public Players Hot, Low Hands Dirty ~5%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 1.0,
                    transportCodec: transportCodec,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportAdapter Sync (Public Players Hot, Medium Hands Dirty ~20%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: mediumRatio,
                    broadcastPlayerRatio: 1.0,
                    transportCodec: transportCodec,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportAdapter Sync (Public Players Hot, High Hands Dirty ~80%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 1.0,
                    transportCodec: transportCodec,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            )
        ]
    }
    
    static func get(
        suiteType: BenchmarkSuiteType,
        transportDirtyTrackingOverride: Bool? = nil,
        dirtyRatioOverride: Double? = nil,
        transportEncodingOverride: TransportEncoding? = nil
    ) -> [BenchmarkSuiteConfig] {
        if suiteType == .all {
            return all(
                transportDirtyTrackingOverride: transportDirtyTrackingOverride,
                dirtyRatioOverride: dirtyRatioOverride,
                transportEncodingOverride: transportEncodingOverride
            )
        }
        return all(
            transportDirtyTrackingOverride: transportDirtyTrackingOverride,
            dirtyRatioOverride: dirtyRatioOverride,
            transportEncodingOverride: transportEncodingOverride
        ).filter { $0.type == suiteType }
    }
}
