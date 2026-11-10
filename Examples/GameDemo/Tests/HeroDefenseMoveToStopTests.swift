import Foundation
import Testing
@testable import SwiftStateTree
@testable import GameContent

/// What stopping the players' MoveTo does to a land (#469). network-impairment's load clients send
/// one PlayAction and one MoveTo per player per second (`cell.py`'s `--move-to-rate 1`: a random
/// target in the world), and the convergence check stops both as it starts. After the check, the
/// live monster count fell from 30 to about 23-24 per land in every run, with kills down and
/// arrivals up. `HeroDefenseFreezeResumeTests` rules out the freeze and the PlayActions, but its
/// players never move. Here each player sends seeded MoveTo at 1/s, laid out like the runs (5
/// players, no spawn ramp, the stop at tick 4183), with and without the stop, on several lands.
/// The stop alone reproduces the drop: it's the game's response to players that stop moving, not
/// the convergence check's freeze, which is a pure pause.
// Thousands of ticks of synchronous work per run: serialized, and yielding every tick, so it holds at most
// one cooperative-pool thread and hands it back (Notes/solutions/2026-11-11-cpu-bound-tests-starve-the-cooperative-pool.md).
@Suite("Hero Defense MoveTo stop", .serialized)
struct HeroDefenseMoveToStopTests {
    // Long enough for the read-out window after the stop: 30 s from 10 s after it (4383..<4983).
    static let ticks = 5000
    static let stopTick = 4183
    static let players = 5
    static let ticksPerMove = 20  // 1 MoveTo/s per player at 20 Hz
    static let lands = 4

    /// Per tick: the land's live, killed and reached-base counts.
    struct Step: Equatable {
        let live: Int
        let killed: Int
        let reachedBase: Int
    }

    /// A small deterministic generator for the targets (the load client draws them uniformly in the world).
    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    }

    /// One land for `ticks` ticks, each player sending MoveTo at 1/s (offset across the second, as
    /// the client's spread send mode does), stopped from `stopAt` on when given.
    static func run(land: Int, stopAt: Int?) async throws -> [Step] {
        var services = LandServices()
        services.register(GameConfigProviderService(provider: DefaultGameConfigProvider(spawnRampTicks: 0)),
                          as: GameConfigProviderService.self)
        let stats = HeroDefenseStatsRecorder()
        services.register(stats, as: HeroDefenseStatsRecorder.self)
        let keeper = LandKeeper<HeroDefenseState>(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            services: services,
            autoStartLoops: false
        )
        let landID = "hero-defense:moveto-\(land)"
        await keeper.setLandID(landID)
        let ids = (0..<players).map { (PlayerID("p\($0)"), ClientID("c\($0)"), SessionID("s\($0)")) }
        for (player, client, session) in ids {
            try await keeper.join(playerID: player, clientID: client, sessionID: session)
        }
        var random = SplitMix(state: UInt64(land) &* 0x1000_0001)
        var steps: [Step] = []
        var totals = (killed: 0, reachedBase: 0)
        for i in 0..<ticks {
            if stopAt.map({ i < $0 }) ?? true {
                for (k, (player, client, session)) in ids.enumerated() where i % ticksPerMove == (k * ticksPerMove / players) {
                    let event = MoveToEvent(x: random.unit() * GameConfig.WORLD_WIDTH, y: random.unit() * GameConfig.WORLD_HEIGHT)
                    try await keeper.handleClientEvent(AnyClientEvent(event), playerID: player, clientID: client, sessionID: session)
                }
            }
            await keeper.stepTickOnce()
            await Task.yield()
            let state = await keeper.currentState()
            if let sample = stats.takeWindow()[landID] {
                totals = (sample.killed, sample.reachedBase)
            }
            steps.append(Step(live: state.monsters.count, killed: totals.killed, reachedBase: totals.reachedBase))
        }
        return steps
    }

    static func median(_ values: [Int]) -> Double {
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? Double(sorted[sorted.count / 2])
            : Double(sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    @Test("Stopping MoveTo at tick 4183: what the live count, kills and arrivals do after it")
    func stoppingMoveTo() async throws {
        let window = 600  // 30 s before the stop, and 30 s from 10 s after it, as the runs were read
        var rows: [String] = []
        for land in 0..<Self.lands {
            let moving = try await Self.run(land: land, stopAt: nil)
            let stopped = try await Self.run(land: land, stopAt: Self.stopTick)
            // The two runs are the same land with the same inputs until the stop.
            #expect(Array(moving[..<Self.stopTick]) == Array(stopped[..<Self.stopTick]))
            let before = Self.stopTick - window..<Self.stopTick
            let after = (Self.stopTick + 200)..<(Self.stopTick + 200 + window)
            func rate(_ steps: [Step], _ r: Range<Int>, _ pick: (Step) -> Int) -> Double {
                Double(pick(steps[r.upperBound - 1]) - pick(steps[r.lowerBound])) * 20 / Double(r.count - 1)
            }
            let liveBefore = Self.median(stopped[before].map(\.live))
            let liveAfter = (Self.median(stopped[after].map(\.live)), Self.median(moving[after].map(\.live)))
            let kills = (rate(stopped, after, \.killed), rate(moving, after, \.killed))
            let arrivals = (rate(stopped, after, \.reachedBase), rate(moving, after, \.reachedBase))
            rows.append("land \(land): live before \(liveBefore), after: stopped \(liveAfter.0), still moving \(liveAfter.1); "
                        + "kills/s before \(rate(stopped, before, \.killed)), after: stopped \(kills.0), moving \(kills.1); "
                        + "arrivals/s before \(rate(stopped, before, \.reachedBase)), after: stopped \(arrivals.0), moving \(arrivals.1)")
            // The drop the runs showed (#469), from the stop alone: with the players standing where their
            // last MoveTo took them, fewer monsters are killed, more reach the base, and fewer are live,
            // against the same land still moving. On 2026-11-10's read: live 22-25 against 29-30, kills
            // 3.2-3.9/s against 4.0-4.5, arrivals 2.8-3.4/s against 2.1-2.6, in every land.
            #expect(liveAfter.0 <= liveAfter.1 - 3, "land \(land): live \(liveAfter.0) stopped against \(liveAfter.1) moving")
            #expect(kills.0 < kills.1, "land \(land): kills/s \(kills.0) stopped against \(kills.1) moving")
            #expect(arrivals.0 > arrivals.1, "land \(land): arrivals/s \(arrivals.0) stopped against \(arrivals.1) moving")
        }
        print("[HeroDefenseMoveToStop] " + rows.joined(separator: " | "))
    }
}
