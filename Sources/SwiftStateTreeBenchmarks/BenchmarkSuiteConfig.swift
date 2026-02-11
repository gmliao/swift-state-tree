// Sources/SwiftStateTreeBenchmarks/BenchmarkSuiteConfig.swift

import Foundation
import SwiftStateTree

/// Available benchmark suite types
enum BenchmarkSuiteType: String, CaseIterable {
    case singleThreaded = "single"
    case diff = "diff"
    case mirrorVsMacro = "mirror"
    case transportAdapterSync = "transport-sync"
    case transportAdapterSyncPlayers = "transport-sync-players"
    case transportAdapterConcurrentStability = "transport-concurrent-stability"
    case all = "all"

    var displayName: String {
        switch self {
        case .singleThreaded: return "Single-threaded Execution"
        case .diff: return "Standard vs Optimized Diff Comparison"
        case .mirrorVsMacro: return "Mirror vs Macro Performance Comparison"
        case .transportAdapterSync: return "TransportAdapter Sync Performance"
        case .transportAdapterSyncPlayers: return "TransportAdapter Sync Performance (Broadcast Players)"
        case .transportAdapterConcurrentStability: return "TransportAdapter Concurrent Sync Stability"
        case .all: return "All Suites"
        }
    }

    var description: String {
        switch self {
        case .singleThreaded: return "Sequential execution on main thread"
        case .diff: return "Compare standard diff vs optimized diff (with dirty tracking) performance"
        case .mirrorVsMacro: return "Compare Mirror-based vs Macro-generated code"
        case .transportAdapterSync: return "TransportAdapter sync performance benchmark"
        case .transportAdapterSyncPlayers: return "TransportAdapter sync benchmark with broadcast players mutated each tick"
        case .transportAdapterConcurrentStability: return "TransportAdapter concurrent sync stability and correctness test"
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
        playerCountsOverride: [Int]? = nil
    ) -> [BenchmarkSuiteConfig] {
        // If override provided, clamp to [0, 1] to避免無效值
        let clampedRatio = dirtyRatioOverride.map { max(0.0, min($0, 1.0)) }

        // Use override for all tiers if provided; otherwise use各自預設
        let lowRatio = clampedRatio ?? 0.05
        let mediumRatio = clampedRatio ?? 0.20
        let highRatio = clampedRatio ?? 0.80

        // Use player counts override if provided; otherwise use defaults
        let defaultPlayerCounts = [4, 10, 20, 30, 50]
        let playerCounts = playerCountsOverride ?? defaultPlayerCounts

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
            // TransportAdapter Sync benchmarks with不同「玩家變更比例」預設：
            // - Low  (~5%)   : 少量玩家變更，偏靜態或慢速遊戲
            // - Medium (~20%): 一般即時遊戲（預設比例）
            // - High (~80%) : 極端壓力測試，接近所有玩家每 tick 都在變
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportSync-Parallel-Low5%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,  // Test multiple player counts for comprehensive results
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 0.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportSync-Parallel-Medium20%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: mediumRatio,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportSync-Parallel-High80%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: highRatio,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
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
                name: "TransportSyncPlayers-Hot-Parallel-Low5%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportSyncPlayers-Hot-Parallel-Medium20%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: mediumRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportSyncPlayers-Hot-Parallel-High80%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 100,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            // Encoding mode comparison: Separate serial and parallel suites
            // Low activity scenario (少更新情境) - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportSync-Serial-Low5%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 0.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            // Note: TransportSync-Parallel-Low5% removed (parallel encoding feature removed)
            // High activity scenario (大量使用者更新情境) - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportSync-Serial-High80%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 0.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            // Note: TransportSync-Parallel-High80% removed (parallel encoding feature removed)
            // Encoding mode comparison for transport-sync-players (Public Players Hot)
            // Low activity scenario - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportSyncPlayers-Hot-Serial-Low5%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            // Note: TransportSyncPlayers-Hot-Parallel-Low5% removed (parallel encoding feature removed)
            // High activity scenario - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportSyncPlayers-Hot-Serial-High80%",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: playerCounts,
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            // Note: TransportSyncPlayers-Hot-Parallel-High80% removed (parallel encoding feature removed)
            // Concurrent stability tests - verify parallel sync operations maintain correctness
            BenchmarkSuiteConfig(
                type: .transportAdapterConcurrentStability,
                name: "ConcurrentStability-Parallel-5Concurrent",
                runner: TransportAdapterConcurrentStabilityBenchmarkRunner(
                    playerCounts: playerCounts,
                    concurrentSyncs: 5,
                    iterations: 100,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterConcurrentStability,
                name: "ConcurrentStability-Serial-5Concurrent",
                runner: TransportAdapterConcurrentStabilityBenchmarkRunner(
                    playerCounts: playerCounts,
                    concurrentSyncs: 5,
                    iterations: 100,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 100
                    ),
                    BenchmarkConfig(
                        name: "Medium-10C",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 100
                    )
                ]
            ),
            BenchmarkSuiteConfig(
                type: .transportAdapterConcurrentStability,
                name: "ConcurrentStability-Parallel-10Concurrent",
                runner: TransportAdapterConcurrentStabilityBenchmarkRunner(
                    playerCounts: playerCounts,
                    concurrentSyncs: 10,
                    iterations: 50,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small-5C",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    )
                ]
            ),
        ]
    }

    static func get(
        suiteType: BenchmarkSuiteType,
        transportDirtyTrackingOverride: Bool? = nil,
        dirtyRatioOverride: Double? = nil,
        playerCountsOverride: [Int]? = nil
    ) -> [BenchmarkSuiteConfig] {
        if suiteType == .all {
            return all(
                transportDirtyTrackingOverride: transportDirtyTrackingOverride,
                dirtyRatioOverride: dirtyRatioOverride,
                playerCountsOverride: playerCountsOverride
            )
        }
        return all(
            transportDirtyTrackingOverride: transportDirtyTrackingOverride,
            dirtyRatioOverride: dirtyRatioOverride,
            playerCountsOverride: playerCountsOverride
        ).filter { $0.type == suiteType }
    }
}
