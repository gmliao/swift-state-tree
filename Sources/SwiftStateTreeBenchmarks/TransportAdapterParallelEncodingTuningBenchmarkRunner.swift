// Sources/SwiftStateTreeBenchmarks/TransportAdapterParallelEncodingTuningBenchmarkRunner.swift

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Benchmark runner for tuning parallel encoding concurrency in TransportAdapter.
///
/// This runner sweeps multiple `maxConcurrency` values and compares them against
/// a serial baseline to identify the player-count threshold where parallel encoding
/// becomes beneficial.
struct TransportAdapterParallelEncodingTuningBenchmarkRunner: BenchmarkRunner {
    let playerCounts: [Int]
    let concurrencyLevels: [Int]
    let dirtyPlayerRatio: Double
    let broadcastPlayerRatio: Double
    let enableDirtyTracking: Bool
    let includeSerialBaseline: Bool

    /// Store all results for multi-player-count benchmarks.
    var allCollectedResults: [BenchmarkResult] = []

    init(
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        concurrencyLevels: [Int] = [1, 2, 4, 8, 16],
        dirtyPlayerRatio: Double = 0.20,
        broadcastPlayerRatio: Double = 0.0,
        enableDirtyTracking: Bool = true,
        includeSerialBaseline: Bool = true
    ) {
        self.playerCounts = playerCounts
        self.concurrencyLevels = Self.normalizeConcurrencyLevels(concurrencyLevels)
        self.dirtyPlayerRatio = dirtyPlayerRatio
        self.broadcastPlayerRatio = broadcastPlayerRatio
        self.enableDirtyTracking = enableDirtyTracking
        self.includeSerialBaseline = includeSerialBaseline
    }

    mutating func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        print("  TransportAdapter Parallel Encoding Tuning Benchmark")
        print("  ====================================================")
        print("  Concurrency levels: \(concurrencyLevels.map(String.init).joined(separator: ", "))")
        if includeSerialBaseline {
            print("  Baseline: Serial encoding")
        }

        allCollectedResults = []
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

            var baselineResult: BenchmarkResult? = nil
            if includeSerialBaseline {
                print("    Serial encoding mode...")
                let serialResult = await benchmarkSync(
                    state: testState,
                    playerIDs: testPlayerIDs,
                    iterations: config.iterations,
                    enableParallelEncoding: false,
                    parallelEncodingMaxConcurrency: nil
                )
                baselineResult = serialResult
                allResults.append(serialResult)
                print("    Serial:   \(String(format: "%.4f", serialResult.averageTime * 1000))ms")
            }

            for concurrency in concurrencyLevels {
                print("    Parallel encoding (maxConcurrency=\(concurrency))...")
                let parallelResult = await benchmarkSync(
                    state: testState,
                    playerIDs: testPlayerIDs,
                    iterations: config.iterations,
                    enableParallelEncoding: true,
                    parallelEncodingMaxConcurrency: concurrency
                )
                allResults.append(parallelResult)

                let parallelMs = parallelResult.averageTime * 1000
                if let baseline = baselineResult {
                    let serialMs = baseline.averageTime * 1000
                    let speedup = serialMs / max(parallelMs, 0.001)
                    print("    Parallel: \(String(format: "%.4f", parallelMs))ms, Speedup: \(String(format: "%.2fx", speedup))")
                } else {
                    print("    Parallel: \(String(format: "%.4f", parallelMs))ms")
                }
            }
        }

        allCollectedResults = allResults

        return allResults.first ?? BenchmarkResult(
            config: config,
            averageTime: 0,
            minTime: 0,
            maxTime: 0,
            snapshotSize: 0,
            throughput: 0,
            executionMode: "TransportAdapter Parallel Encoding Tuning",
            bytesPerPlayer: nil
        )
    }

    private static func normalizeConcurrencyLevels(_ levels: [Int]) -> [Int] {
        var seen: Set<Int> = []
        var normalized: [Int] = []
        for level in levels where level > 0 {
            if seen.insert(level).inserted {
                normalized.append(level)
            }
        }
        return normalized
    }

    private func benchmarkSync(
        state: BenchmarkStateRootNode,
        playerIDs: [PlayerID],
        iterations: Int,
        enableParallelEncoding: Bool,
        parallelEncodingMaxConcurrency: Int?
    ) async -> BenchmarkResult {
        // Convert BenchmarkStateRootNode to BenchmarkStateForSync
        var syncState = BenchmarkStateForSync()
        syncState.players = state.players
        syncState.hands = state.hands
        syncState.round = state.round

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

        let definition = Land("benchmark-parallel-tuning", using: BenchmarkStateForSync.self) {
            Rules {
                HandleAction(BenchmarkMutationAction.self) { state, action, _ in
                    applyDeterministicMutations(state: &state, iteration: action.iteration)
                    return BenchmarkMutationResponse(applied: true)
                }
            }
        }

        let benchmarkLogger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.benchmark.parallel.tuning",
            scope: nil,
            logLevel: .error,
            useColors: false
        )

        let mockTransport = CountingTransport()

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
            codec: JSONTransportCodec(),
            enableParallelEncoding: enableParallelEncoding,
            logger: benchmarkLogger
        )
        await keeper.setTransport(adapter)
        await mockTransport.setDelegate(adapter)


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

        await adapter.syncNow()

        let actionPlayerID = playerIDs.first ?? PlayerID("player_0")
        let actionClientID = ClientID("client-0")
        let actionSessionID = SessionID("session-0")

        let warmupIterations = min(5, iterations / 10)
        if warmupIterations > 0 {
            for i in 0..<warmupIterations {
                let action = BenchmarkMutationAction(iteration: i)
                _ = try? await keeper.handleAction(
                    action,
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
            _ = try? await keeper.handleAction(
                action,
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

        var modeLabel = enableDirtyTracking ? "DirtyTracking: On" : "DirtyTracking: Off"
        modeLabel += ", Encoding: \(enableParallelEncoding ? "Parallel" : "Serial")"
        if enableParallelEncoding, let maxConcurrency = parallelEncodingMaxConcurrency {
            modeLabel += ", MaxConcurrency: \(maxConcurrency)"
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
            snapshotSize: Int(totalBytesPerSync.rounded()),
            throughput: throughput,
            executionMode: modeLabel,
            bytesPerPlayer: bytesPerPlayer
        )
    }
}
