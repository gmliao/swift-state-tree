// Examples/GameDemo/Sources/EncodingBenchmark/HashCostBenchmark.swift
//
// `--hash-cost`: what the replay state hash costs per tick, full state (record 2.4, #180)
// against the broadcast view (records before 2.4), on Hero Defense rooms stepped by their real
// tick handler. Only meaningful from a `-c release` build.

import Foundation
import GameContent
import SwiftStateTree

struct HashCostSample {
    var fullNs: [UInt64] = []
    var broadcastNs: [UInt64] = []
    var fullBytes: [Int] = []
    var broadcastBytes: [Int] = []
    var monsters: [Int] = []
    /// Sum over rooms of each tick's hash time.
    var fullTickNs: [UInt64] = []
    var broadcastTickNs: [UInt64] = []
}

private func nanos(_ body: () -> Void) -> UInt64 {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return DispatchTime.now().uptimeNanoseconds - start
}

private func percentile<T: BinaryInteger>(_ values: [T], _ p: Double) -> T {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
    return sorted[index]
}

private func encodedBytes(_ snapshot: StateSnapshot) -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(snapshot).count) ?? -1
}

/// Steps `roomCount` Hero Defense rooms of `playersPerRoom` players through `warmupTicks`, then
/// measures both hash definitions on every room for `measuredTicks` ticks. The two hashes run
/// in alternating order per tick, so neither always runs on a warm cache.
func runHashCost(roomCount: Int, playersPerRoom: Int, warmupTicks: Int, measuredTicks: Int) async -> HashCostSample {
    let benchmarkLogger = createGameLogger(scope: "EncodingBenchmark", logLevel: .error)
    var keepers: [LandKeeper<HeroDefenseState>] = []
    for roomIndex in 0 ..< roomCount {
        var services = LandServices()
        services.register(GameConfigProviderService(provider: DefaultGameConfigProvider()), as: GameConfigProviderService.self)
        let keeper = LandKeeper<HeroDefenseState>(
            definition: HeroDefense.makeLand(maxPlayers: max(10, playersPerRoom)),
            initialState: HeroDefenseState(),
            services: services,
            autoStartLoops: false,
            transport: nil,
            logger: benchmarkLogger
        )
        for playerIndex in 0 ..< playersPerRoom {
            _ = try? await keeper.join(
                playerID: PlayerID("room\(roomIndex)-player-\(playerIndex)"),
                clientID: ClientID("room\(roomIndex)-client-\(playerIndex)"),
                sessionID: SessionID("room\(roomIndex)-session-\(playerIndex)")
            )
        }
        keepers.append(keeper)
    }
    for _ in 0 ..< warmupTicks {
        for keeper in keepers { await keeper.stepTickOnce() }
    }

    var sample = HashCostSample()
    for tick in 0 ..< measuredTicks {
        var fullTick: UInt64 = 0
        var broadcastTick: UInt64 = 0
        for keeper in keepers {
            await keeper.stepTickOnce()
            let state = await keeper.currentState()
            var full = ""
            var broadcast = ""
            let measureFull = { fullTick += nanos { full = ReevaluationEngine.calculateStateHash(state) } }
            let measureBroadcast = { broadcastTick += nanos { broadcast = ReevaluationEngine.calculateBroadcastViewHash(state) } }
            let before = (fullTick, broadcastTick)
            if tick % 2 == 0 { measureFull(); measureBroadcast() } else { measureBroadcast(); measureFull() }
            sample.fullNs.append(fullTick - before.0)
            sample.broadcastNs.append(broadcastTick - before.1)
            precondition(!full.isEmpty && !broadcast.isEmpty)
            if tick == measuredTicks - 1 || tick % 50 == 0 {
                let fullSnapshot = try? ReevaluationEngine.hashedSnapshot(state, definition: .fullState)
                sample.fullBytes.append(fullSnapshot.map(encodedBytes) ?? -1)
                sample.broadcastBytes.append((try? ReevaluationEngine.hashedSnapshot(state, definition: .broadcastView)).map(encodedBytes) ?? -1)
                if case .object(let monsters)? = fullSnapshot?.values["monsters"] {
                    sample.monsters.append(monsters.count)
                }
            }
        }
        sample.fullTickNs.append(fullTick)
        sample.broadcastTickNs.append(broadcastTick)
    }
    return sample
}

func runHashCostMatrix(config: BenchmarkConfig) async {
    let roomCounts = config.roomCounts.isEmpty ? [1, 10, 50, 100] : config.roomCounts
    let playersList = config.playersPerRoomList.isEmpty ? [config.playersPerRoom] : config.playersPerRoomList
    let warmup = config.hashCostWarmupTicks
    let measured = config.iterations
    let tickBudgetNs = Double(GameConfig.TICK_INTERVAL_MS) * 1_000_000
    print("Hash cost per tick (full state vs broadcast view), Hero Defense, warmup \(warmup) ticks, \(measured) measured ticks")
    print("rooms | ppr | full µs/room p50 p99 | broadcast µs/room p50 p99 | ratio p50 | full µs/tick (all rooms) p50 p99 | share of \(GameConfig.TICK_INTERVAL_MS) ms tick | bytes full/broadcast | monsters")
    var rows: [[String: Any]] = []
    for roomCount in roomCounts {
        for ppr in playersList {
            let s = await runHashCost(roomCount: roomCount, playersPerRoom: ppr, warmupTicks: warmup, measuredTicks: measured)
            let fullP50 = Double(percentile(s.fullNs, 0.5)) / 1000
            let fullP99 = Double(percentile(s.fullNs, 0.99)) / 1000
            let bP50 = Double(percentile(s.broadcastNs, 0.5)) / 1000
            let bP99 = Double(percentile(s.broadcastNs, 0.99)) / 1000
            let tickFullP50 = Double(percentile(s.fullTickNs, 0.5)) / 1000
            let tickFullP99 = Double(percentile(s.fullTickNs, 0.99)) / 1000
            let tickBP50 = Double(percentile(s.broadcastTickNs, 0.5)) / 1000
            // Each land ticks on its own; the share is one room's hash against its own tick.
            let roomShare = Double(percentile(s.fullNs, 0.5)) / tickBudgetNs
            let fullBytes = percentile(s.fullBytes, 0.5)
            let broadcastBytes = percentile(s.broadcastBytes, 0.5)
            let monsters = percentile(s.monsters, 0.5)
            print(String(format: "%5d | %3d | %8.1f %8.1f | %8.1f %8.1f | %5.2fx | %10.1f %10.1f | %6.3f%% | %d/%d | %d",
                         roomCount, ppr, fullP50, fullP99, bP50, bP99, bP50 > 0 ? fullP50 / bP50 : 0,
                         tickFullP50, tickFullP99, roomShare * 100, fullBytes, broadcastBytes, monsters))
            rows.append([
                "rooms": roomCount,
                "playersPerRoom": ppr,
                "warmupTicks": warmup,
                "measuredTicks": measured,
                "fullStateHashUsPerRoom": ["p50": fullP50, "p99": fullP99],
                "broadcastViewHashUsPerRoom": ["p50": bP50, "p99": bP99],
                "fullStateHashUsPerTickAllRooms": ["p50": tickFullP50, "p99": tickFullP99],
                "broadcastViewHashUsPerTickAllRooms": ["p50": tickBP50],
                "fullStateShareOfRoomTickBudget": roomShare,
                "tickIntervalMs": GameConfig.TICK_INTERVAL_MS,
                "hashedBytesMedian": ["fullState": fullBytes, "broadcastView": broadcastBytes],
                "monstersMedian": monsters,
            ])
        }
    }
    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    saveResultsToJSON(rows, filename: "hash-cost-\(measured)ticks-\(timestamp).json", benchmarkConfig: [
        "mode": "hash-cost",
        "roomCounts": roomCounts,
        "playersPerRoomList": playersList,
        "warmupTicks": warmup,
        "measuredTicks": measured,
        "buildConfiguration": buildConfigurationName(),
    ])
}
