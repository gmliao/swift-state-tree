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
    case all = "all"
    
    var displayName: String {
        switch self {
        case .singleThreaded: return "Single-threaded Execution"
        case .diff: return "Standard vs Optimized Diff Comparison"
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
        dirtyRatioOverride: Double? = nil
    ) -> [BenchmarkSuiteConfig] {
        // If override provided, clamp to [0, 1] to避免無效值
        let clampedRatio = dirtyRatioOverride.map { max(0.0, min($0, 1.0)) }
        
        // Use override for all tiers if provided; otherwise use各自預設
        let lowRatio = clampedRatio ?? 0.05
        let mediumRatio = clampedRatio ?? 0.20
        let highRatio = clampedRatio ?? 0.80
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
                name: "TransportAdapter Sync (Low Dirty ~5%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [4, 10, 20, 30, 50],
                    dirtyPlayerRatio: lowRatio,
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
            // Encoding mode comparison: Separate serial and parallel suites
            // Low activity scenario (少更新情境) - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Sync - Serial Encoding (Low Activity ~5%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 0.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: false
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            ),
            // Low activity scenario - Parallel encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Sync - Parallel Encoding (Low Activity ~5%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 0.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            ),
            // High activity scenario (大量使用者更新情境) - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Sync - Serial Encoding (High Activity ~80%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 0.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: false
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            ),
            // High activity scenario - Parallel encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSync,
                name: "TransportAdapter Sync - Parallel Encoding (High Activity ~80%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 0.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            ),
            // Encoding mode comparison for transport-sync-players (Public Players Hot)
            // Low activity scenario - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportAdapter Sync (Players Hot) - Serial Encoding (Low Activity ~5%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: false
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            ),
            // Low activity scenario - Parallel encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportAdapter Sync (Players Hot) - Parallel Encoding (Low Activity ~5%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: lowRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            ),
            // High activity scenario - Serial encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportAdapter Sync (Players Hot) - Serial Encoding (High Activity ~80%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: false
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            ),
            // High activity scenario - Parallel encoding
            BenchmarkSuiteConfig(
                type: .transportAdapterSyncPlayers,
                name: "TransportAdapter Sync (Players Hot) - Parallel Encoding (High Activity ~80%)",
                runner: TransportAdapterSyncBenchmarkRunner(
                    playerCounts: [10, 20, 30, 50],
                    dirtyPlayerRatio: highRatio,
                    broadcastPlayerRatio: 1.0,
                    enableDirtyTracking: transportDirtyTrackingOverride ?? true,
                    enableParallelEncoding: true
                ),
                configurations: [
                    BenchmarkConfig(
                        name: "Small State",
                        playerCount: 10,
                        cardsPerPlayer: 5,
                        iterations: 50
                    ),
                    BenchmarkConfig(
                        name: "Medium State",
                        playerCount: 50,
                        cardsPerPlayer: 10,
                        iterations: 50
                    )
                ]
            )
        ]
    }
    
    static func get(
        suiteType: BenchmarkSuiteType,
        transportDirtyTrackingOverride: Bool? = nil,
        dirtyRatioOverride: Double? = nil
    ) -> [BenchmarkSuiteConfig] {
        if suiteType == .all {
            return all(
                transportDirtyTrackingOverride: transportDirtyTrackingOverride,
                dirtyRatioOverride: dirtyRatioOverride
            )
        }
        return all(
            transportDirtyTrackingOverride: transportDirtyTrackingOverride,
            dirtyRatioOverride: dirtyRatioOverride
        ).filter { $0.type == suiteType }
    }
}
