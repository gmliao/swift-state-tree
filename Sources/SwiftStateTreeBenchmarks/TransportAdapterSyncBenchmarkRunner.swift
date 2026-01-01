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
/// Supports comparing serial vs parallel encoding modes to evaluate performance benefits
/// of parallel JSON encoding for multiple players.
struct TransportAdapterSyncBenchmarkRunner: BenchmarkRunner {
    let playerCounts: [Int]

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

    /// Whether to compare serial vs parallel encoding modes.
    /// When true, runs benchmark twice (once with parallel encoding enabled, once disabled)
    /// and compares the results.
    let compareEncodingModes: Bool

    /// Explicitly set parallel encoding mode (nil = use default based on codec)
    let enableParallelEncoding: Bool?

    init(
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        dirtyPlayerRatio: Double = 0.20,
        broadcastPlayerRatio: Double = 0.0,
        enableDirtyTracking: Bool = true,
        compareEncodingModes: Bool = false,
        enableParallelEncoding: Bool? = nil
    ) {
        self.playerCounts = playerCounts
        self.dirtyPlayerRatio = dirtyPlayerRatio
        self.broadcastPlayerRatio = broadcastPlayerRatio
        self.enableDirtyTracking = enableDirtyTracking
        self.compareEncodingModes = compareEncodingModes
        self.enableParallelEncoding = enableParallelEncoding
    }

    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        // This runner doesn't use the standard config, but we need to conform to the protocol
        // We'll run our own benchmark logic

        if compareEncodingModes {
            print("  TransportAdapter Sync Performance Benchmark")
            print("  Serial vs Parallel Encoding Comparison")
            print("  ===========================================")
        } else {
        print("  TransportAdapter Sync Performance Benchmark")
        print("  ===========================================")
        }

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

            if compareEncodingModes {
                // Create a deep copy of testState for serial test to avoid state contamination
                var serialTestState = BenchmarkStateRootNode()
                serialTestState.round = testState.round
                for (pid, player) in testState.players {
                    serialTestState.players[pid] = BenchmarkPlayerState(
                        name: player.name,
                        hpCurrent: player.hpCurrent,
                        hpMax: player.hpMax
                    )
                }
                for (pid, hand) in testState.hands {
                    serialTestState.hands[pid] = BenchmarkHandState(
                        ownerID: hand.ownerID,
                        cards: hand.cards.map { BenchmarkCard(id: $0.id, suit: $0.suit, rank: $0.rank) }
                    )
                }

                // Run benchmark with parallel encoding disabled (serial)
                print("    Serial encoding mode...")
                let serialResult = await benchmarkSync(
                    state: serialTestState,
                    playerIDs: testPlayerIDs,
                    iterations: config.iterations,
                    enableParallelEncoding: false
                )

                // Create a fresh deep copy of testState for parallel test
                var parallelTestState = BenchmarkStateRootNode()
                parallelTestState.round = testState.round
                for (pid, player) in testState.players {
                    parallelTestState.players[pid] = BenchmarkPlayerState(
                        name: player.name,
                        hpCurrent: player.hpCurrent,
                        hpMax: player.hpMax
                    )
                }
                for (pid, hand) in testState.hands {
                    parallelTestState.hands[pid] = BenchmarkHandState(
                        ownerID: hand.ownerID,
                        cards: hand.cards.map { BenchmarkCard(id: $0.id, suit: $0.suit, rank: $0.rank) }
                    )
                }

                // Run benchmark with parallel encoding enabled
                print("    Parallel encoding mode...")
                let parallelResult = await benchmarkSync(
                    state: parallelTestState,
                    playerIDs: testPlayerIDs,
                    iterations: config.iterations,
                    enableParallelEncoding: true
                )

                // Compare results
                let serialMs = serialResult.averageTime * 1000
                let parallelMs = parallelResult.averageTime * 1000
                let speedup = serialMs / max(parallelMs, 0.001)

                print("    Serial:   \(String(format: "%.4f", serialMs))ms")
                print("    Parallel: \(String(format: "%.4f", parallelMs))ms")
                print("    Speedup:  \(String(format: "%.2fx", speedup))")

                // Use parallel result as the main result (it's the default mode)
                allResults.append(parallelResult)
            } else {
                // Test sync performance with specified encoding mode
            let result = await benchmarkSync(
                state: testState,
                playerIDs: testPlayerIDs,
                    iterations: config.iterations,
                    enableParallelEncoding: enableParallelEncoding  // Use configured encoding mode
            )

            print("    Average: \(String(format: "%.4f", result.averageTime * 1000))ms")

            allResults.append(result)
            }
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
        iterations: Int,
        enableParallelEncoding: Bool? = nil
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
        // Create adapter with parallel encoding control
        let adapter = TransportAdapter<BenchmarkStateForSync>(
            keeper: keeper,
            transport: mockTransport,
            landID: "benchmark-land",
            createGuestSession: nil,
            enableLegacyJoin: false,
            enableDirtyTracking: enableDirtyTracking,
            codec: JSONTransportCodec(),  // Use JSON codec to enable parallel encoding option
            enableParallelEncoding: enableParallelEncoding,  // Control parallel encoding via parameter
            logger: benchmarkLogger
        )
        await keeper.setTransport(adapter)
        await mockTransport.setDelegate(adapter)

        // Log actual encoding mode for debugging
        let actualEncodingMode = await adapter.isParallelEncodingEnabled()
        let configValue = enableParallelEncoding?.description ?? "nil (default)"
        print("    [DEBUG] Config: enableParallelEncoding=\(configValue), Actual: \(actualEncodingMode), Players: \(playerIDs.count)")

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
        // This wait happens BEFORE measurement starts, so it's not included in the timing
        try? await Task.sleep(for: .milliseconds(2))

        #if canImport(Foundation)
        let startTime = Date().timeIntervalSince1970
        #else
        let startTime = ContinuousClock.now
        #endif

        for _ in 0..<iterations {
            // Measure syncNow() which includes:
            // 1. beginSync() - may wait for actor serialization if tick handler is running
            // 2. Core sync operations (extract snapshot, compute diff, encode, send)
            // 3. endSync()
            //
            // Note: beginSync() wait time is minimal in practice (tick handlers are fast),
            // and is necessary to ensure state consistency. The core sync operations
            // (diff computation, encoding) are the main performance bottleneck.
            await adapter.syncNow()  // Sync with actual diffs

            // Small sleep between iterations to allow tick to modify state for next iteration
            // This sleep is NOT included in the measurement to get accurate sync performance
            // We subtract this time from the total to measure only core sync time
            if iterations > 1 {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        #if canImport(Foundation)
        let totalTime = Date().timeIntervalSince1970 - startTime
        #else
        let endTime = ContinuousClock.now
        let totalTime = endTime.timeIntervalSince(startTime)
        #endif

        // Subtract sleep time from total (only for iterations > 1)
        // This ensures we only measure the actual sync execution time, not the wait time
        // between iterations. The sleep time is used to allow tick handler to modify state
        // for the next iteration, but is not part of the core sync performance.
        let sleepTime = iterations > 1 ? Double(iterations - 1) * 0.001 : 0.0
        let actualSyncTime = totalTime - sleepTime
        let averageTime = actualSyncTime / Double(iterations)
        let throughput = Double(iterations) / actualSyncTime

        // Build mode label
        var modeLabel = enableDirtyTracking ? "DirtyTracking: On" : "DirtyTracking: Off"
        if let enableParallel = enableParallelEncoding {
            modeLabel += ", Encoding: \(enableParallel ? "Parallel" : "Serial")"
        } else {
            modeLabel += ", Encoding: Default"
        }

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

