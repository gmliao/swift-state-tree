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

@Payload
struct BenchmarkMutationAction: ActionPayload {
    typealias Response = BenchmarkMutationResponse
    let iteration: Int
}

@Payload
struct BenchmarkMutationResponse: ResponsePayload {
    let applied: Bool
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

    /// Incremental sync mode for A/B performance comparison.
    ///
    /// - off:    diff-only path
    /// - shadow: diff path + incremental patch metrics collection
    /// - on:     reserved for full incremental transport path
    let incrementalSyncMode: TransportAdapter<BenchmarkStateForSync>.IncrementalSyncMode
    
    /// Store all results for multi-player-count benchmarks
    var allCollectedResults: [BenchmarkResult] = []

    init(
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        dirtyPlayerRatio: Double = 0.20,
        broadcastPlayerRatio: Double = 0.0,
        enableDirtyTracking: Bool = true,
        compareEncodingModes: Bool = false,
        enableParallelEncoding: Bool? = nil,
        incrementalSyncMode: TransportAdapter<BenchmarkStateForSync>.IncrementalSyncMode = .off
    ) {
        self.playerCounts = playerCounts
        self.dirtyPlayerRatio = dirtyPlayerRatio
        self.broadcastPlayerRatio = broadcastPlayerRatio
        self.enableDirtyTracking = enableDirtyTracking
        self.compareEncodingModes = compareEncodingModes
        self.enableParallelEncoding = enableParallelEncoding
        self.incrementalSyncMode = incrementalSyncMode
    }

    mutating func run(
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

        allCollectedResults = []  // Reset for this run
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
                if let serialPerPlayer = serialResult.bytesPerPlayer, let parallelPerPlayer = parallelResult.bytesPerPlayer {
                    print("    Serial payload:   \(serialResult.snapshotSize) bytes total (per player: \(serialPerPlayer) bytes)")
                    print("    Parallel payload: \(parallelResult.snapshotSize) bytes total (per player: \(parallelPerPlayer) bytes)")
                } else {
                    print("    Serial payload:   \(serialResult.snapshotSize) bytes")
                    print("    Parallel payload: \(parallelResult.snapshotSize) bytes")
                }
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
            if let bytesPerPlayer = result.bytesPerPlayer {
                print("    Total Payload: \(result.snapshotSize) bytes (per player: \(bytesPerPlayer) bytes)")
            } else {
                print("    Payload: \(result.snapshotSize) bytes")
            }

            allResults.append(result)
            }
        }

        // Store all results for access by BenchmarkSuite
        allCollectedResults = allResults
        
        // Return the first result as the protocol requires
        // (The summary will show all results via allCollectedResults)
        return allResults.first ?? BenchmarkResult(
            config: config,
            averageTime: 0,
            minTime: 0,
            maxTime: 0,
            snapshotSize: 0,
            throughput: 0,
            executionMode: "TransportAdapter Sync Comparison",
            bytesPerPlayer: nil
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

        // Create minimal land definition with deterministic mutations.
        // This ensures consistent diffs across serial vs parallel runs.
        // Clamp dirty ratio to [0, 1] to avoid invalid values.
        let clampedDirtyRatio = max(0.0, min(dirtyPlayerRatio, 1.0))
        let clampedBroadcastRatio = max(0.0, min(broadcastPlayerRatio, 1.0))

        @Sendable func applyDeterministicMutations(
            state: inout BenchmarkStateForSync,
            iteration: Int
        ) {
            state.round += 1

            let allPlayerIDs = state.hands.keys.sorted { $0.rawValue < $1.rawValue }
            guard !allPlayerIDs.isEmpty else { return }

            let rawCount = Int(Double(allPlayerIDs.count) * clampedDirtyRatio)
            let numPlayersToModify = max(1, min(rawCount, allPlayerIDs.count))
            let startIndex = (iteration * 7) % allPlayerIDs.count

            for offset in 0..<numPlayersToModify {
                let playerID = allPlayerIDs[(startIndex + offset) % allPlayerIDs.count]
                guard var hand = state.hands[playerID], !hand.cards.isEmpty else {
                    continue
                }
                let cardIndex = (iteration + offset) % hand.cards.count
                let oldCard = hand.cards[cardIndex]
                let suit = (oldCard.suit + 1 + (iteration % 3)) % 4
                let rank = (oldCard.rank + 1 + (iteration % 7)) % 13
                hand.cards[cardIndex] = BenchmarkCard(
                    id: oldCard.id,
                    suit: suit,
                    rank: rank
                )
                state.hands[playerID] = hand
            }

            if clampedBroadcastRatio > 0.0 {
                let rawBroadcastCount = Int(Double(allPlayerIDs.count) * clampedBroadcastRatio)
                let numBroadcastPlayersToModify = max(1, min(rawBroadcastCount, allPlayerIDs.count))
                let broadcastStart = (iteration * 3) % allPlayerIDs.count

                for offset in 0..<numBroadcastPlayersToModify {
                    let playerID = allPlayerIDs[(broadcastStart + offset) % allPlayerIDs.count]
                    guard var player = state.players[playerID] else {
                        continue
                    }
                    var delta = ((iteration + offset) % 2 == 0) ? 1 : -1
                    if player.hpCurrent <= 0 {
                        delta = 1
                    } else if player.hpCurrent >= player.hpMax {
                        delta = -1
                    }
                    player.hpCurrent = max(0, min(player.hpMax, player.hpCurrent + delta))
                    state.players[playerID] = player
                }
            }
        }

        let definition = Land("benchmark-sync", using: BenchmarkStateForSync.self) {
            Rules {
                HandleAction(BenchmarkMutationAction.self) { state, action, _ in
                    applyDeterministicMutations(state: &state, iteration: action.iteration)
                    return BenchmarkMutationResponse(applied: true)
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

        // Create mock transport that counts encoded payload bytes.
        let mockTransport = CountingTransport()

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
            incrementalSyncMode: incrementalSyncMode,
            codec: JSONTransportCodec(),  // Use JSON codec to enable parallel encoding option
            enableParallelEncoding: enableParallelEncoding,  // Control parallel encoding via parameter
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

        let actionPlayerID = playerIDs.first ?? PlayerID("player_0")
        let actionClientID = ClientID("client-0")
        let actionSessionID = SessionID("session-0")

        let warmupIterations = min(5, iterations / 10)
        if warmupIterations > 0 {
            for i in 0..<warmupIterations {
                let action = BenchmarkMutationAction(iteration: i)
                let envelope = ActionEnvelope(
                    typeIdentifier: String(describing: BenchmarkMutationAction.self),
                    payload: AnyCodable(action)
                )
                _ = try? await keeper.handleActionEnvelope(
                    envelope,
                    playerID: actionPlayerID,
                    clientID: actionClientID,
                    sessionID: actionSessionID
                )
                await adapter.syncNow()
            }
        }

        await mockTransport.resetCounts()

        var totalSyncTime: TimeInterval = 0
        for i in 0..<iterations {
            let iterationIndex = warmupIterations + i
            let action = BenchmarkMutationAction(iteration: iterationIndex)
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: BenchmarkMutationAction.self),
                payload: AnyCodable(action)
            )
            _ = try? await keeper.handleActionEnvelope(
                envelope,
                playerID: actionPlayerID,
                clientID: actionClientID,
                sessionID: actionSessionID
            )

            #if canImport(Foundation)
            let startTime = Date().timeIntervalSince1970
            #else
            let startTime = ContinuousClock.now
            #endif

            await adapter.syncNow()

            #if canImport(Foundation)
            let endTime = Date().timeIntervalSince1970
            totalSyncTime += endTime - startTime
            #else
            let endTime = ContinuousClock.now
            totalSyncTime += endTime.timeIntervalSince(startTime)
            #endif
        }

        let averageTime = iterations > 0 ? totalSyncTime / Double(iterations) : 0
        let throughput = totalSyncTime > 0 ? Double(iterations) / totalSyncTime : 0
        let sendCounts = await mockTransport.snapshotCounts()
        let totalBytesPerSync = iterations > 0 ? Double(sendCounts.bytes) / Double(iterations) : 0.0
        let bytesPerPlayer = playerIDs.count > 0 ? Int(totalBytesPerSync / Double(playerIDs.count)) : nil

        // Build mode label
        var modeLabel = enableDirtyTracking ? "DirtyTracking: On" : "DirtyTracking: Off"
        if let enableParallel = enableParallelEncoding {
            modeLabel += ", Encoding: \(enableParallel ? "Parallel" : "Serial")"
        } else {
            modeLabel += ", Encoding: Default"
        }
        modeLabel += ", Incremental: \(incrementalSyncMode.rawValue)"

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
            snapshotSize: Int(totalBytesPerSync.rounded()),
            throughput: throughput,
            executionMode: modeLabel,
            bytesPerPlayer: bytesPerPlayer
        )
    }
}
