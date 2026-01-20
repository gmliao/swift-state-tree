// Sources/SwiftStateTreeBenchmarks/TransportAdapterMultiRoomParallelEncodingBenchmarkRunner.swift

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Benchmark runner for multi-room parallel encoding behavior in TransportAdapter.
///
/// This runner creates multiple rooms and runs their tick + sync in parallel to
/// understand how overall throughput scales with room count. Parallel encoding
/// uses automatic concurrency configuration based on player count per room.
struct TransportAdapterMultiRoomParallelEncodingBenchmarkRunner: BenchmarkRunner {
    enum TickMode: String {
        case synchronized
        case staggered
    }

    let roomCounts: [Int]
    let playerCounts: [Int]
    let tickMode: TickMode
    let tickStrides: [Int]
    let dirtyPlayerRatio: Double
    let broadcastPlayerRatio: Double
    let enableDirtyTracking: Bool
    let includeSerialBaseline: Bool

    /// Store all results for multi-room benchmarks.
    var allCollectedResults: [BenchmarkResult] = []

    init(
        roomCounts: [Int] = [1, 2, 4, 8],
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        tickMode: TickMode = .staggered,
        tickStrides: [Int] = [1, 2, 3, 4],
        dirtyPlayerRatio: Double = 0.20,
        broadcastPlayerRatio: Double = 0.0,
        enableDirtyTracking: Bool = true,
        includeSerialBaseline: Bool = true
    ) {
        self.roomCounts = Self.normalizePositive(roomCounts)
        self.playerCounts = Self.normalizePositive(playerCounts)
        self.tickMode = tickMode
        let normalizedStrides = Self.normalizePositive(tickStrides)
        self.tickStrides = normalizedStrides.isEmpty ? [1] : normalizedStrides
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
        print("  TransportAdapter Multi-Room Parallel Encoding Benchmark")
        print("  =======================================================")
        print("  Rooms: \(roomCounts.map(String.init).joined(separator: ", "))")
        print("  Players per room: \(playerCounts.map(String.init).joined(separator: ", "))")
        print("  Parallel encoding uses automatic concurrency configuration based on player count")
        print("  Tick mode: \(tickMode.rawValue) (strides: \(tickStrides.map(String.init).joined(separator: ", ")))")
        if includeSerialBaseline {
            print("  Baseline: Serial encoding")
        }

        allCollectedResults = []
        var allResults: [BenchmarkResult] = []

        for roomCount in roomCounts {
            print("\n  Testing with \(roomCount) rooms...")

            for playerCount in playerCounts {
                print("    Players per room: \(playerCount)")

                var baselineResult: BenchmarkResult? = nil
                if includeSerialBaseline {
                    print("      Serial encoding mode...")
                    let serialResult = await benchmarkMultiRoomSync(
                        roomCount: roomCount,
                        playerCount: playerCount,
                        iterations: config.iterations,
                        cardsPerPlayer: config.cardsPerPlayer,
                        enableParallelEncoding: false
                    )
                    baselineResult = serialResult
                    allResults.append(serialResult)
                }

                print("      Parallel encoding (auto-configured concurrency)...")
                let parallelResult = await benchmarkMultiRoomSync(
                    roomCount: roomCount,
                    playerCount: playerCount,
                    iterations: config.iterations,
                    cardsPerPlayer: config.cardsPerPlayer,
                    enableParallelEncoding: true
                )
                allResults.append(parallelResult)

                if let baseline = baselineResult {
                    let serialMs = baseline.averageTime * 1000
                    let parallelMs = parallelResult.averageTime * 1000
                    let speedup = serialMs / max(parallelMs, 0.001)
                    print("      Speedup vs serial: \(String(format: "%.2fx", speedup))")
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
            executionMode: "TransportAdapter Multi-Room Parallel Encoding",
            bytesPerPlayer: nil
        )
    }

    private struct RoomContext: Sendable {
        let keeper: LandKeeper<BenchmarkStateForSync>
        let adapter: TransportAdapter<BenchmarkStateForSync>
        let transport: CountingTransport
        let actionPlayerID: PlayerID
        let actionClientID: ClientID
        let actionSessionID: SessionID
        let tickStride: Int
        let tickOffset: Int
    }

    private static func normalizePositive(_ values: [Int]) -> [Int] {
        var seen: Set<Int> = []
        var normalized: [Int] = []
        for value in values where value > 0 {
            if seen.insert(value).inserted {
                normalized.append(value)
            }
        }
        return normalized
    }

    private func benchmarkMultiRoomSync(
        roomCount: Int,
        playerCount: Int,
        iterations: Int,
        cardsPerPlayer: Int,
        enableParallelEncoding: Bool
    ) async -> BenchmarkResult {
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

        let definition = Land("benchmark-multiroom-sync", using: BenchmarkStateForSync.self) {
            Rules {
                HandleAction(BenchmarkMutationAction.self) { state, action, _ in
                    applyDeterministicMutations(state: &state, iteration: action.iteration)
                    return BenchmarkMutationResponse(applied: true)
                }
            }
        }

        let benchmarkLogger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.benchmark.multiroom",
            scope: nil,
            logLevel: .error,
            useColors: false
        )

        var rooms: [RoomContext] = []
        rooms.reserveCapacity(roomCount)

        for roomIndex in 0..<roomCount {
            var syncState = BenchmarkStateForSync()
            let playerIDs = (0..<playerCount).map { PlayerID("room\(roomIndex)-player\($0)") }

            for pid in playerIDs {
                syncState.players[pid] = BenchmarkPlayerState(
                    name: "Player \(pid.rawValue)",
                    hpCurrent: 100,
                    hpMax: 100
                )
                syncState.hands[pid] = BenchmarkHandState(
                    ownerID: pid,
                    cards: (0..<cardsPerPlayer).map { BenchmarkCard(id: $0, suit: $0 % 4, rank: $0 % 13) }
                )
            }
            syncState.round = 1

            let transport = CountingTransport()
            let keeper = LandKeeper(
                definition: definition,
                initialState: syncState,
                transport: nil,
                logger: benchmarkLogger
            )
            let adapter = TransportAdapter<BenchmarkStateForSync>(
                keeper: keeper,
                transport: transport,
                landID: "benchmark-room-\(roomIndex)",
                createGuestSession: nil,
                enableLegacyJoin: false,
                enableDirtyTracking: enableDirtyTracking,
                codec: JSONTransportCodec(),
                enableParallelEncoding: enableParallelEncoding,
                logger: benchmarkLogger
            )
            await keeper.setTransport(adapter)
            await transport.setDelegate(adapter)


            for (index, playerID) in playerIDs.enumerated() {
                let sessionID = SessionID("room\(roomIndex)-session-\(index)")
                let clientID = ClientID("room\(roomIndex)-client-\(index)")
                await adapter.onConnect(sessionID: sessionID, clientID: clientID)

                let playerSession = PlayerSession(
                    playerID: playerID.rawValue,
                    deviceID: "device-\(roomIndex)-\(index)",
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

            let actionPlayerID = playerIDs.first ?? PlayerID("room\(roomIndex)-player-0")
            let actionClientID = ClientID("room\(roomIndex)-client-0")
            let actionSessionID = SessionID("room\(roomIndex)-session-0")
            let stride = tickStrides[roomIndex % tickStrides.count]
            let offset = roomIndex % stride

            rooms.append(RoomContext(
                keeper: keeper,
                adapter: adapter,
                transport: transport,
                actionPlayerID: actionPlayerID,
                actionClientID: actionClientID,
                actionSessionID: actionSessionID,
                tickStride: stride,
                tickOffset: offset
            ))
        }

        let stableRooms = rooms

        let warmupIterations = min(5, iterations / 10)
        if warmupIterations > 0 {
            for i in 0..<warmupIterations {
                let iterationIndex = i
                await runIteration(
                    rooms: stableRooms,
                    iteration: iterationIndex,
                    tickMode: tickMode
                )
            }
        }

        for room in stableRooms {
            await room.transport.resetCounts()
        }

        var totalSyncTime: TimeInterval = 0
        for i in 0..<iterations {
            let iterationIndex = warmupIterations + i

            #if canImport(Foundation)
            let startTime = Date().timeIntervalSince1970
            #else
            let startTime = ContinuousClock.now
            #endif

            await runIteration(
                rooms: stableRooms,
                iteration: iterationIndex,
                tickMode: tickMode
            )

            #if canImport(Foundation)
            let endTime = Date().timeIntervalSince1970
            totalSyncTime += endTime - startTime
            #else
            let endTime = ContinuousClock.now
            totalSyncTime += endTime.timeIntervalSince(startTime)
            #endif
        }

        var totalBytes = 0
        for room in stableRooms {
            let counts = await room.transport.snapshotCounts()
            totalBytes += counts.bytes
        }

        let averageTime = iterations > 0 ? totalSyncTime / Double(iterations) : 0
        let throughput = totalSyncTime > 0 ? Double(iterations) / totalSyncTime : 0
        let totalBytesPerSync = iterations > 0 ? Double(totalBytes) / Double(iterations) : 0.0
        let totalPlayers = roomCount * playerCount
        let bytesPerPlayer = totalPlayers > 0 ? Int(totalBytesPerSync / Double(totalPlayers)) : nil

        var modeLabel = enableDirtyTracking ? "DirtyTracking: On" : "DirtyTracking: Off"
        modeLabel += ", Encoding: \(enableParallelEncoding ? "Parallel" : "Serial")"
        modeLabel += ", Rooms: \(roomCount)"
        modeLabel += ", Tick: \(tickMode.rawValue)"

        return BenchmarkResult(
            config: BenchmarkConfig(
                name: "Rooms:\(roomCount) PerRoom:\(playerCount)",
                playerCount: totalPlayers,
                cardsPerPlayer: cardsPerPlayer,
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

    private func runIteration(
        rooms: [RoomContext],
        iteration: Int,
        tickMode: TickMode
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for room in rooms {
                if tickMode == .staggered {
                    let shouldTick = (iteration + room.tickOffset) % room.tickStride == 0
                    if !shouldTick {
                        continue
                    }
                }
                group.addTask {
                    let action = BenchmarkMutationAction(iteration: iteration)
                    let envelope = ActionEnvelope(
                        typeIdentifier: String(describing: BenchmarkMutationAction.self),
                        payload: AnyCodable(action)
                    )
                    _ = try? await room.keeper.handleActionEnvelope(
                        envelope,
                        playerID: room.actionPlayerID,
                        clientID: room.actionClientID,
                        sessionID: room.actionSessionID
                    )
                    await room.adapter.syncNow()
                }
            }
            await group.waitForAll()
        }
    }
}
