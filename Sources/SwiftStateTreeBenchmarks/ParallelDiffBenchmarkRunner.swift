// Sources/SwiftStateTreeBenchmarks/ParallelDiffBenchmarkRunner.swift

import Darwin
import Foundation
import SwiftStateTree

final class PerPlayerDiffEngine: @unchecked Sendable {
    // Each instance is pinned to a single player and used by one task per iteration.
    var engine = SyncEngine()
}

actor ThreadRecorder {
    private var threadIDs: Set<UInt64> = []

    func recordCurrentThread() {
        threadIDs.insert(currentThreadID())
    }

    func reset() {
        threadIDs.removeAll()
    }

    func uniqueThreadCount() -> Int {
        threadIDs.count
    }
}

private func currentThreadID() -> UInt64 {
    var tid: UInt64 = 0
    pthread_threadid_np(nil, &tid)
    return tid
}

struct ParallelDiffBenchmarkRunner: BenchmarkRunner {
    enum Mode: String {
        case serial = "serial"
        case parallel = "parallel"
        case both = "both"

        static var current: Mode {
            if let envValue = ProcessInfo.processInfo.environment["PARALLEL_DIFF_MODE"]?.lowercased(),
               let mode = Mode(rawValue: envValue) {
                return mode
            }
            return .both
        }
    }

    private struct Metrics {
        let averageTime: TimeInterval
        let minTime: TimeInterval
        let maxTime: TimeInterval
        let throughput: Double
        let threadCount: Int?
    }

    private struct SyncFieldSets {
        let broadcastFields: Set<String>
        let perPlayerFields: Set<String>
    }

    let playerCounts: [Int]
    let dirtyPlayerRatio: Double
    let broadcastPlayerRatio: Double
    let enableDirtyTracking: Bool
    let chunkSize: Int
    let probeParallelism: Bool

    init(
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        dirtyPlayerRatio: Double = 0.20,
        broadcastPlayerRatio: Double = 0.0,
        enableDirtyTracking: Bool = true,
        chunkSize: Int? = nil,
        probeParallelism: Bool? = nil
    ) {
        self.playerCounts = playerCounts
        self.dirtyPlayerRatio = dirtyPlayerRatio
        self.broadcastPlayerRatio = broadcastPlayerRatio
        self.enableDirtyTracking = enableDirtyTracking
        if let chunkSize, chunkSize > 0 {
            self.chunkSize = chunkSize
        } else if let envValue = ProcessInfo.processInfo.environment["PARALLEL_DIFF_CHUNK"],
                  let envChunk = Int(envValue),
                  envChunk > 0 {
            self.chunkSize = envChunk
        } else {
            self.chunkSize = 1
        }
        if let probeParallelism {
            self.probeParallelism = probeParallelism
        } else {
            let envValue = ProcessInfo.processInfo.environment["PARALLEL_DIFF_PROBE"]?.lowercased()
            self.probeParallelism = envValue != "0"
        }
    }

    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        _ = state
        _ = playerID

        print("  Parallel Diff Experiment (per-player diff only)")
        print("  ===============================================")
        print("  Mode: \(Mode.current.rawValue), Chunk: \(chunkSize), DirtyTracking: \(enableDirtyTracking ? "On" : "Off")")

        var firstResult: BenchmarkResult?
        let mode = Mode.current
        let coreCount = ProcessInfo.processInfo.processorCount

        for playerCount in playerCounts {
            print("\n  Testing with \(playerCount) players...")
            let (baseState, playerIDs) = makeSyncState(
                playerCount: playerCount,
                cardsPerPlayer: config.cardsPerPlayer
            )
            let fieldSets = resolveSyncFieldSets(from: baseState)
            let serialMetrics: Metrics?
            if mode == .serial || mode == .both {
                let metrics = await runSerial(
                    baseState: baseState,
                    playerIDs: playerIDs,
                    iterations: config.iterations,
                    fieldSets: fieldSets
                )
                print("    Serial avg: \(String(format: "%.4f", metrics.averageTime * 1000))ms")
                serialMetrics = metrics
                if mode == .serial {
                    firstResult = makeResult(
                        config: config,
                        playerCount: playerCount,
                        metrics: metrics,
                        executionMode: "Diff (Serial)"
                    )
                }
            } else {
                serialMetrics = nil
            }

            let parallelMetrics: Metrics?
            if mode == .parallel || mode == .both {
                let metrics = await runParallel(
                    baseState: baseState,
                    playerIDs: playerIDs,
                    iterations: config.iterations,
                    fieldSets: fieldSets
                )
                print("    Parallel avg: \(String(format: "%.4f", metrics.averageTime * 1000))ms")
                if let threadCount = metrics.threadCount {
                    print("    Parallel probe: \(threadCount) unique threads used")
                }
                parallelMetrics = metrics
                if mode == .parallel {
                    firstResult = makeResult(
                        config: config,
                        playerCount: playerCount,
                        metrics: metrics,
                        executionMode: "Diff (Concurrent TaskGroup)"
                    )
                }
            } else {
                parallelMetrics = nil
            }

            if mode == .both, let serialMetrics, let parallelMetrics {
                let speedup = serialMetrics.averageTime / parallelMetrics.averageTime
                let efficiency = (speedup / Double(coreCount)) * 100.0
                print("    Speedup: \(String(format: "%.2fx", speedup)) (theoretical: \(coreCount)x)")
                print("    Efficiency: \(String(format: "%.1f", efficiency))%")
                firstResult = makeResult(
                    config: config,
                    playerCount: playerCount,
                    metrics: parallelMetrics,
                    executionMode: "Diff (Concurrent TaskGroup)"
                )
            }
        }

        return firstResult ?? BenchmarkResult(
            config: config,
            averageTime: 0,
            minTime: 0,
            maxTime: 0,
            snapshotSize: 0,
            throughput: 0,
            executionMode: "Diff (Concurrent TaskGroup)"
        )
    }

    private func makeSyncState(
        playerCount: Int,
        cardsPerPlayer: Int
    ) -> (BenchmarkStateForSync, [PlayerID]) {
        var syncState = BenchmarkStateForSync()
        let playerIDs = (0..<playerCount).map { PlayerID("player_\($0)") }

        for playerID in playerIDs {
            syncState.players[playerID] = BenchmarkPlayerState(
                name: "Player \(playerID.rawValue)",
                hpCurrent: 100,
                hpMax: 100
            )
            syncState.hands[playerID] = BenchmarkHandState(
                ownerID: playerID,
                cards: (0..<cardsPerPlayer).map { BenchmarkCard(id: $0, suit: $0 % 4, rank: $0 % 13) }
            )
        }
        syncState.round = 1
        syncState.clearDirty()
        return (syncState, playerIDs)
    }

    private func resolveSyncFieldSets(from state: BenchmarkStateForSync) -> SyncFieldSets {
        let syncFields = state.getSyncFields()
        let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
        let perPlayerFieldNames = Set(syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }.map { $0.name })
        return SyncFieldSets(broadcastFields: broadcastFieldNames, perPlayerFields: perPlayerFieldNames)
    }

    private func runSerial(
        baseState: BenchmarkStateForSync,
        playerIDs: [PlayerID],
        iterations: Int,
        fieldSets: SyncFieldSets
    ) async -> Metrics {
        var state = baseState
        var broadcastEngine = SyncEngine()
        let perPlayerEngines = playerIDs.map { _ in PerPlayerDiffEngine() }

        _ = await runSerialRound(
            state: state,
            playerIDs: playerIDs,
            broadcastEngine: &broadcastEngine,
            perPlayerEngines: perPlayerEngines,
            fieldSets: fieldSets
        )

        var times: [TimeInterval] = []
        times.reserveCapacity(iterations)

        for iteration in 0..<iterations {
            applyTick(
                state: &state,
                playerIDs: playerIDs,
                iteration: iteration,
                dirtyPlayerRatio: dirtyPlayerRatio,
                broadcastPlayerRatio: broadcastPlayerRatio
            )

            let elapsed = await measureTimeAsync {
                _ = await runSerialRound(
                    state: state,
                    playerIDs: playerIDs,
                    broadcastEngine: &broadcastEngine,
                    perPlayerEngines: perPlayerEngines,
                    fieldSets: fieldSets
                )
            }
            times.append(elapsed)

            if enableDirtyTracking {
                state.clearDirty()
            }
        }

        return summarize(times: times, threadCount: nil)
    }

    private func runParallel(
        baseState: BenchmarkStateForSync,
        playerIDs: [PlayerID],
        iterations: Int,
        fieldSets: SyncFieldSets
    ) async -> Metrics {
        var state = baseState
        var broadcastEngine = SyncEngine()
        let perPlayerEngines = playerIDs.map { _ in PerPlayerDiffEngine() }
        let recorder = ThreadRecorder()

        _ = await runParallelRound(
            state: state,
            playerIDs: playerIDs,
            broadcastEngine: &broadcastEngine,
            perPlayerEngines: perPlayerEngines,
            fieldSets: fieldSets,
            threadRecorder: nil
        )

        var threadCount: Int? = nil
        if probeParallelism {
            await recorder.reset()
            _ = await runParallelRound(
                state: state,
                playerIDs: playerIDs,
                broadcastEngine: &broadcastEngine,
                perPlayerEngines: perPlayerEngines,
                fieldSets: fieldSets,
                threadRecorder: recorder
            )
            threadCount = await recorder.uniqueThreadCount()
        }

        var times: [TimeInterval] = []
        times.reserveCapacity(iterations)

        for iteration in 0..<iterations {
            applyTick(
                state: &state,
                playerIDs: playerIDs,
                iteration: iteration,
                dirtyPlayerRatio: dirtyPlayerRatio,
                broadcastPlayerRatio: broadcastPlayerRatio
            )

            let elapsed = await measureTimeAsync {
                _ = await runParallelRound(
                    state: state,
                    playerIDs: playerIDs,
                    broadcastEngine: &broadcastEngine,
                    perPlayerEngines: perPlayerEngines,
                    fieldSets: fieldSets,
                    threadRecorder: nil
                )
            }
            times.append(elapsed)

            if enableDirtyTracking {
                state.clearDirty()
            }
        }

        return summarize(times: times, threadCount: threadCount)
    }

    private func runSerialRound(
        state: BenchmarkStateForSync,
        playerIDs: [PlayerID],
        broadcastEngine: inout SyncEngine,
        perPlayerEngines: [PerPlayerDiffEngine],
        fieldSets: SyncFieldSets
    ) async {
        let modes = resolveSnapshotModes(state: state, fieldSets: fieldSets)
        let broadcastSnapshot = try! broadcastEngine.extractBroadcastSnapshot(from: state, mode: modes.broadcastMode)
        let broadcastDiff = broadcastEngine.computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            mode: modes.broadcastMode
        )

        for (index, playerID) in playerIDs.enumerated() {
            let engineBox = perPlayerEngines[index]
            let perPlayerSnapshot = try! engineBox.engine.extractPerPlayerSnapshot(
                for: playerID,
                from: state,
                mode: modes.perPlayerMode
            )
            _ = engineBox.engine.generateUpdateFromBroadcastDiff(
                for: playerID,
                broadcastDiff: broadcastDiff,
                perPlayerSnapshot: perPlayerSnapshot,
                perPlayerMode: modes.perPlayerMode
            )
        }
    }

    private func runParallelRound(
        state: BenchmarkStateForSync,
        playerIDs: [PlayerID],
        broadcastEngine: inout SyncEngine,
        perPlayerEngines: [PerPlayerDiffEngine],
        fieldSets: SyncFieldSets,
        threadRecorder: ThreadRecorder?
    ) async {
        let modes = resolveSnapshotModes(state: state, fieldSets: fieldSets)
        let broadcastSnapshot = try! broadcastEngine.extractBroadcastSnapshot(from: state, mode: modes.broadcastMode)
        let broadcastDiff = broadcastEngine.computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            mode: modes.broadcastMode
        )

        let playerCount = playerIDs.count
        let chunkSize = max(1, min(self.chunkSize, playerCount))

        await withTaskGroup(of: Void.self) { group in
            var startIndex = 0
            while startIndex < playerCount {
                let endIndex = min(startIndex + chunkSize, playerCount)
                let chunkStart = startIndex
                let chunkEnd = endIndex

                group.addTask {
                    if let threadRecorder {
                        await threadRecorder.recordCurrentThread()
                    }
                    for index in chunkStart..<chunkEnd {
                        let playerID = playerIDs[index]
                        let engineBox = perPlayerEngines[index]
                        let perPlayerSnapshot = try! engineBox.engine.extractPerPlayerSnapshot(
                            for: playerID,
                            from: state,
                            mode: modes.perPlayerMode
                        )
                        _ = engineBox.engine.generateUpdateFromBroadcastDiff(
                            for: playerID,
                            broadcastDiff: broadcastDiff,
                            perPlayerSnapshot: perPlayerSnapshot,
                            perPlayerMode: modes.perPlayerMode
                        )
                    }
                }

                startIndex = endIndex
            }
        }
    }

    private func resolveSnapshotModes(
        state: BenchmarkStateForSync,
        fieldSets: SyncFieldSets
    ) -> (broadcastMode: SnapshotMode, perPlayerMode: SnapshotMode) {
        if enableDirtyTracking, state.isDirty() {
            let dirtyFields = state.getDirtyFields()
            let broadcastFields = dirtyFields.intersection(fieldSets.broadcastFields)
            let perPlayerFields = dirtyFields.intersection(fieldSets.perPlayerFields)

            let broadcastMode = broadcastFields.isEmpty ? SnapshotMode.all : SnapshotMode.dirtyTracking(broadcastFields)
            let perPlayerMode = perPlayerFields.isEmpty ? SnapshotMode.all : SnapshotMode.dirtyTracking(perPlayerFields)
            return (broadcastMode, perPlayerMode)
        }

        return (.all, .all)
    }

    private func applyTick(
        state: inout BenchmarkStateForSync,
        playerIDs: [PlayerID],
        iteration: Int,
        dirtyPlayerRatio: Double,
        broadcastPlayerRatio: Double
    ) {
        state.round += 1
        guard !playerIDs.isEmpty else { return }

        let clampedDirtyRatio = max(0.0, min(dirtyPlayerRatio, 1.0))
        let dirtyCount = max(1, min(Int(Double(playerIDs.count) * clampedDirtyRatio), playerIDs.count))
        let startIndex = iteration % playerIDs.count

        for offset in 0..<dirtyCount {
            let playerID = playerIDs[(startIndex + offset) % playerIDs.count]
            if var hand = state.hands[playerID], !hand.cards.isEmpty {
                let cardIndex = (iteration + offset) % hand.cards.count
                let oldCard = hand.cards[cardIndex]
                hand.cards[cardIndex] = BenchmarkCard(
                    id: oldCard.id,
                    suit: (oldCard.suit + 1 + offset) % 4,
                    rank: (oldCard.rank + 1 + iteration) % 13
                )
                state.hands[playerID] = hand
            }
        }

        let clampedBroadcastRatio = max(0.0, min(broadcastPlayerRatio, 1.0))
        if clampedBroadcastRatio > 0.0 {
            let broadcastCount = max(1, min(Int(Double(playerIDs.count) * clampedBroadcastRatio), playerIDs.count))
            let startBroadcastIndex = (iteration * 3) % playerIDs.count
            let delta = (iteration % 3) - 1

            for offset in 0..<broadcastCount {
                let playerID = playerIDs[(startBroadcastIndex + offset) % playerIDs.count]
                if var player = state.players[playerID] {
                    player.hpCurrent = max(0, min(player.hpMax, player.hpCurrent + delta))
                    state.players[playerID] = player
                }
            }
        }
    }

    private func summarize(times: [TimeInterval], threadCount: Int?) -> Metrics {
        let average = times.reduce(0, +) / Double(times.count)
        let minTime = times.min() ?? 0
        let maxTime = times.max() ?? 0
        let throughput = 1.0 / average
        return Metrics(
            averageTime: average,
            minTime: minTime,
            maxTime: maxTime,
            throughput: throughput,
            threadCount: threadCount
        )
    }

    private func makeResult(
        config: BenchmarkConfig,
        playerCount: Int,
        metrics: Metrics,
        executionMode: String
    ) -> BenchmarkResult {
        BenchmarkResult(
            config: BenchmarkConfig(
                name: config.name,
                playerCount: playerCount,
                cardsPerPlayer: config.cardsPerPlayer,
                iterations: config.iterations
            ),
            averageTime: metrics.averageTime,
            minTime: metrics.minTime,
            maxTime: metrics.maxTime,
            snapshotSize: 0,
            throughput: metrics.throughput,
            executionMode: executionMode
        )
    }
}
