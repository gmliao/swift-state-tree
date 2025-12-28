// Sources/SwiftStateTreeBenchmarks/TransportAdapterSyncBenchmarkRunner.swift

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

// MARK: - Benchmark State

@StateNodeBuilder
struct BenchmarkStateForSync: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: BenchmarkPlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: BenchmarkHandState] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

/// Benchmark runner for TransportAdapter sync performance.
///
/// This benchmark simulates a real-world scenario where multiple players are connected
/// and the server needs to sync state changes to all players.
///
/// NOTE: A parallel sync version was tested but did not show performance improvements.
/// Benchmark results showed that TaskGroup overhead and actor isolation costs exceeded
/// the benefits of parallel diff computation. The serial version remains the implementation.
struct TransportAdapterSyncBenchmarkRunner: BenchmarkRunner {
    let playerCounts: [Int]
    let transportCodec: any TransportCodec
    
    /// Approximate ratio of players to modify per tick (0.0 ... 1.0).
    ///
    /// This controls how "hot" the state is:
    /// - ~0.05  (5%)   : low activity,少數玩家有變動
    /// - ~0.20  (20%)  : medium activity（預設），接近一般即時遊戲中等頻率變更
    /// - ~0.80  (80%)  : high activity / 壓力測試，接近「幾乎每個玩家每 tick 都在變」
    ///
    /// NOTE: 這是「玩家數量比例」的近似，實際變動欄位數還會依 state 結構而定。
    let dirtyPlayerRatio: Double
    
    /// Approximate ratio of broadcast player entries to modify per tick (0.0 ... 1.0).
    ///
    /// When `0.0`, the benchmark preserves the original behavior: it only modifies a small
    /// broadcast scalar field (`round`) plus some per-player fields (`hands`).
    ///
    /// When greater than `0.0`, it also mutates `players` (a broadcast dictionary). This is
    /// closer to real-world games where public player state (position/HP/etc.) changes often.
    let broadcastPlayerRatio: Double
    
    /// Whether to enable dirty tracking in TransportAdapter during this benchmark.
    /// - true : use optimized dirty-tracking diff (default)
    /// - false: always generate full diffs and skip clearDirty()
    let enableDirtyTracking: Bool
    
    init(
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        dirtyPlayerRatio: Double = 0.20,
        broadcastPlayerRatio: Double = 0.0,
        transportCodec: any TransportCodec = JSONTransportCodec(),
        enableDirtyTracking: Bool = true
    ) {
        self.playerCounts = playerCounts
        self.dirtyPlayerRatio = dirtyPlayerRatio
        self.broadcastPlayerRatio = broadcastPlayerRatio
        self.transportCodec = transportCodec
        self.enableDirtyTracking = enableDirtyTracking
    }
    
    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        // This runner doesn't use the standard config, but we need to conform to the protocol
        // We'll run our own benchmark logic
        
        print("  TransportAdapter Sync Performance Benchmark")
        print("  ===========================================")
        
        var allResults: [BenchmarkResult] = []
        
        for playerCount in playerCounts {
            print("\n  Testing with \(playerCount) players...")
            
            // Create test state
            var testState = BenchmarkStateRootNode()
            let testPlayerIDs = (0..<playerCount).map { PlayerID("player_\($0)") }
            
            for pid in testPlayerIDs {
                testState.players[pid] = BenchmarkPlayerState(
                    name: "Player \(pid.rawValue)",
                    hpCurrent: 100,
                    hpMax: 100
                )
                testState.hands[pid] = BenchmarkHandState(
                    ownerID: pid,
                    cards: (0..<config.cardsPerPlayer).map { BenchmarkCard(id: $0, suit: $0 % 4, rank: $0 % 13) }
                )
            }
            testState.round = 1
            
            // Test sync performance
            let result = await benchmarkSync(
                state: testState,
                playerIDs: testPlayerIDs,
                iterations: config.iterations
            )
            
            print("    Average: \(String(format: "%.4f", result.averageTime * 1000))ms")
            
            allResults.append(result)
        }
        
        // Return the first result as the protocol requires
        // (The summary will show all results)
        return allResults.first ?? BenchmarkResult(
            config: config,
            averageTime: 0,
            minTime: 0,
            maxTime: 0,
            snapshotSize: 0,
            throughput: 0,
            executionMode: "TransportAdapter Sync Comparison"
        )
    }
    
    private func benchmarkSync(
        state: BenchmarkStateRootNode,
        playerIDs: [PlayerID],
        iterations: Int
    ) async -> BenchmarkResult {
        // Convert BenchmarkStateRootNode to BenchmarkStateForSync
        var syncState = BenchmarkStateForSync()
        syncState.players = state.players
        syncState.hands = state.hands
        syncState.round = state.round
        
        // Create minimal land definition with tick handler to modify state
        // This ensures we have actual state changes to trigger diff computation
        // Clamp dirty ratio to [0, 1] to avoid invalid values
        let clampedDirtyRatio = max(0.0, min(dirtyPlayerRatio, 1.0))
        let clampedBroadcastRatio = max(0.0, min(broadcastPlayerRatio, 1.0))
        
        let definition = Land("benchmark-sync", using: BenchmarkStateForSync.self) {
            Rules {}
            
            Lifetime { (config: inout LifetimeConfig<BenchmarkStateForSync>) in
                config.tickInterval = .milliseconds(1)
                config.tickHandler = { (state: inout BenchmarkStateForSync, ctx: LandContext) in
                    // Modify broadcast field to trigger broadcast diff
                    state.round += 1
                    
                    // Modify per-player fields for a few random players to trigger per-player diffs
                    // This simulates real-world scenarios where some players' data changes
                    let allPlayerIDs = Array(state.hands.keys)
                    guard !allPlayerIDs.isEmpty else { return }
                    
                    // Approximate number of players to modify based on configured ratio.
                    // Always modify at least 1 player to ensure有實際 per-player diff。
                    let rawCount = Int(Double(allPlayerIDs.count) * clampedDirtyRatio)
                    let numPlayersToModify = max(1, min(rawCount, allPlayerIDs.count))
                    
                    // Randomly pick distinct players to modify
                    let selectedPlayers = allPlayerIDs.shuffled().prefix(numPlayersToModify)
                    for playerID in selectedPlayers {
                        // IMPORTANT: keep hand size stable; only mutate existing cards,
                        // do NOT append new ones, so state size stays roughly constant
                        if var hand = state.hands[playerID], !hand.cards.isEmpty {
                            let index = Int.random(in: 0..<hand.cards.count)
                            let oldCard = hand.cards[index]
                            hand.cards[index] = BenchmarkCard(
                                id: oldCard.id,
                                suit: Int.random(in: 0..<4),
                                rank: Int.random(in: 0..<13)
                            )
                            state.hands[playerID] = hand
                        }
                    }
                    
                    // Optionally mutate broadcast player state to simulate public player updates.
                    // This typically makes sync cost dominated by the broadcast `players` dictionary.
                    if clampedBroadcastRatio > 0.0 {
                        let rawBroadcastCount = Int(Double(allPlayerIDs.count) * clampedBroadcastRatio)
                        let numBroadcastPlayersToModify = max(1, min(rawBroadcastCount, allPlayerIDs.count))
                        
                        let selectedBroadcastPlayers = allPlayerIDs.shuffled().prefix(numBroadcastPlayersToModify)
                        for playerID in selectedBroadcastPlayers {
                            if var player = state.players[playerID] {
                                // Keep payload size stable: only mutate scalar fields.
                                let delta = (state.round % 3) - 1 // -1, 0, 1
                                player.hpCurrent = max(0, min(player.hpMax, player.hpCurrent + delta))
                                state.players[playerID] = player
                            }
                        }
                    }
                }
            }
        }
        
        // Create logger with high log level for benchmarks (only show errors)
        let benchmarkLogger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.benchmark",
            scope: nil,
            logLevel: .error,
            useColors: false
        )
        
        // Create mock transport (using WebSocketTransport as base, but we'll track messages)
        let mockTransport = WebSocketTransport(logger: benchmarkLogger)
        
        // Create keeper and adapter with high log level
        let keeper = LandKeeper(
            definition: definition,
            initialState: syncState,
            transport: nil,
            logger: benchmarkLogger
        )
        let adapter = TransportAdapter<BenchmarkStateForSync>(
            keeper: keeper,
            transport: mockTransport,
            landID: "benchmark-land",
            createGuestSession: nil,
            enableLegacyJoin: false,
            enableDirtyTracking: enableDirtyTracking,
            codec: transportCodec,
            logger: benchmarkLogger
        )
        await keeper.setTransport(adapter)
        await mockTransport.setDelegate(adapter)
        
        // Connect and join all players
        for (index, playerID) in playerIDs.enumerated() {
            let sessionID = SessionID("session-\(index)")
            let clientID = ClientID("client-\(index)")
            await adapter.onConnect(sessionID: sessionID, clientID: clientID)
            
            let playerSession = PlayerSession(
                playerID: playerID.rawValue,
                deviceID: "device-\(index)",
                metadata: [:]
            )
            _ = try? await adapter.performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: nil as AuthenticatedInfo?
            )
        }
        
        // Initial sync to populate cache
        await adapter.syncNow()
        
        // Wait a bit for tick to modify state, then warmup
        try? await Task.sleep(for: .milliseconds(10))
        for _ in 0..<min(5, iterations / 10) {
            try? await Task.sleep(for: .milliseconds(2))  // Let tick modify state
            await adapter.syncNow()
        }
        
        // Benchmark: Measure sync performance with state changes
        // Tick is running in background, modifying state periodically
        // We just measure sync performance when state has changed
        // Wait once before starting to ensure state has changed via tick
        try? await Task.sleep(for: .milliseconds(2))
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            await adapter.syncNow()  // Sync with actual diffs
            // Small sleep between iterations to allow tick to modify state for next iteration
            // This sleep is NOT included in the measurement to get accurate sync performance
            if iterations > 1 {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        // Subtract sleep time from total (only for iterations > 1)
        let sleepTime = iterations > 1 ? Double(iterations - 1) * 0.001 : 0.0
        let actualSyncTime = totalTime - sleepTime
        let averageTime = actualSyncTime / Double(iterations)
        let throughput = Double(iterations) / actualSyncTime
        
        let modeLabel = enableDirtyTracking ? "Serial Sync (DirtyTracking: On)"
                                            : "Serial Sync (DirtyTracking: Off)"
        
        return BenchmarkResult(
            config: BenchmarkConfig(
                name: "Sync",
                playerCount: playerIDs.count,
                cardsPerPlayer: state.hands.values.first?.cards.count ?? 0,
                iterations: iterations
            ),
            averageTime: averageTime,
            minTime: averageTime,
            maxTime: averageTime,
            snapshotSize: 0,
            throughput: throughput,
            executionMode: modeLabel
        )
    }
}
