import Foundation
import Testing
@_spi(Testing) @testable import SwiftStateTree
@testable import GameContent

/// A debug freeze must be a pure pause: the convergence check freezes each land, reads its
/// projection and resumes it, and compares against clients that kept the state from before. So a
/// land frozen and resumed mid-run follows the same per-tick trajectory as one that never was.
/// And Hero Defense's monsters don't depend on the load client's PlayActions (they only add to the
/// score), so the actions stopping at the end of a run changes nothing else either. Laid out like
/// the network-impairment no-ramp confirmation run, where the live count fell from 30 to 23 per
/// land after the convergence check: 5 players, no spawn ramp, the freeze and the send stop at
/// tick 4183 (about 210 s of land age).
// Thousands of ticks of synchronous work per run: serialized, and yielding every tick, so it holds at most
// one cooperative-pool thread and hands it back (Notes/solutions/2026-11-11-cpu-bound-tests-starve-the-cooperative-pool.md).
@Suite("Hero Defense freeze and resume", .serialized)
struct HeroDefenseFreezeResumeTests {
    static let ticks = 4600
    static let stopTick = 4183
    static let players = 5
    static let ticksPerAction = 20  // 1 action/s per player at 20 Hz

    /// Per tick: the committed tick, the full-state hash (with the score zeroed when `scoreless`),
    /// and the land's live, spawned, killed and reached-base counts.
    struct Step: Equatable {
        let tick: Int64
        let hash: String
        let live: Int
        let spawned: Int
        let killed: Int
        let reachedBase: Int
    }

    enum Variant { case plain, freeze, actions }

    static func run(_ variant: Variant, scoreless: Bool = false) async throws -> [Step] {
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
        let landID = "hero-defense:freeze-resume"
        await keeper.setLandID(landID)
        let ids = (0..<players).map { (PlayerID("p\($0)"), ClientID("c\($0)"), SessionID(fixed: "s\($0)")) }
        for (player, client, session) in ids {
            try await keeper.join(playerID: player, clientID: client, sessionID: session)
        }
        var steps: [Step] = []
        var totals = (spawned: 0, killed: 0, reachedBase: 0)
        for i in 0..<ticks {
            if variant == .freeze, i == stopTick {
                #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
                let before = await keeper.debugLastCommittedTickId()
                let frozenHash = ReevaluationEngine.calculateStateHash(await keeper.currentState())
                // Ticks asked for while frozen don't run (the tick loop's, here stepped by hand).
                for _ in 0..<5 { await keeper.stepTickOnce() }
                #expect(await keeper.debugLastCommittedTickId() == before)
                #expect(ReevaluationEngine.calculateStateHash(await keeper.currentState()) == frozenHash)
                await keeper.debugResume(generation: 1)
            }
            // Actions go in while the tick that applies them runs (an action can wait for it).
            var sends: [Task<Void, Error>] = []
            if variant == .actions, i < stopTick, i % ticksPerAction == 0 {
                for (player, client, session) in ids {
                    sends.append(Task {
                        let envelope = ActionEnvelope(typeIdentifier: String(describing: PlayAction.self), payload: AnyCodable(PlayAction()))
                        _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
                    })
                }
                // A tick land queues them for the next tick: step it once all five are in.
                var spins = 0
                while await keeper.pendingItemSequencesForTesting().count < players {
                    spins += 1
                    if spins > 100_000 {
                        Issue.record("tick \(i): the actions weren't queued")
                        break
                    }
                    await Task.yield()  // wall-clock: the keeper has no queued-input event to wait on; bounded at 100,000 spins
                }
            }
            await keeper.stepTickOnce()
            await Task.yield()  // wall-clock: cooperative yield between CPU-bound ticks, not a wait
            for send in sends { try await send.value }
            var state = await keeper.currentState()
            if scoreless { state.score = 0 }
            if let sample = stats.takeWindow()[landID] {
                totals = (sample.spawned, sample.killed, sample.reachedBase)
            }
            steps.append(Step(tick: await keeper.debugLastCommittedTickId(), hash: ReevaluationEngine.calculateStateHash(state),
                              live: state.monsters.count, spawned: totals.spawned, killed: totals.killed,
                              reachedBase: totals.reachedBase))
        }
        return steps
    }

    /// The first tick whose step differs, with both sides, or nil when the runs match.
    static func firstDifference(_ a: [Step], _ b: [Step]) -> String? {
        guard a.count == b.count else { return "\(a.count) steps against \(b.count)" }
        guard let i = a.indices.first(where: { a[$0] != b[$0] }) else { return nil }
        return "tick index \(i): \(a[i]) against \(b[i])"
    }

    /// The live count's median per 100 ticks over ticks 3900-4600, from a run's steps.
    static func liveProfile(_ steps: [Step]) -> String {
        stride(from: 3900, to: ticks, by: 100).map { start in
            let window = steps[start..<min(start + 100, steps.count)].map(\.live).sorted()
            return "\(start):\(window[window.count / 2])"
        }.joined(separator: " ")
    }

    @Test("A freeze and resume mid-run leaves every tick's state as it was without one")
    func freezeIsAPause() async throws {
        let plain = try await Self.run(.plain)
        let frozen = try await Self.run(.freeze)
        #expect(plain.count == Self.ticks && plain.last?.tick == Int64(Self.ticks - 1))
        let difference = Self.firstDifference(plain, frozen)
        #expect(difference == nil, "\(difference ?? "")")
        // The run is long enough to have the flows the confirmation run had at the freeze.
        let atStop = plain[Self.stopTick]
        #expect(atStop.killed > 0 && atStop.reachedBase > 0)
        // Without any freeze or send stop: the live count per land around the confirmation run's
        // drop (tick ~4260), and the flows from the freeze tick to the end.
        let end = plain[plain.count - 1]
        print("[HeroDefenseFreezeResume] live median per 100 ticks: \(Self.liveProfile(plain)); from tick \(Self.stopTick): "
              + "spawned \(end.spawned - atStop.spawned), killed \(end.killed - atStop.killed), reached base \(end.reachedBase - atStop.reachedBase)")
    }

    @Test("PlayActions, and their stop, change only the score: the monsters' trajectory is the same")
    func actionsTouchOnlyTheScore() async throws {
        let plain = try await Self.run(.plain, scoreless: true)
        let acted = try await Self.run(.actions, scoreless: true)
        let difference = Self.firstDifference(plain, acted)
        #expect(difference == nil, "\(difference ?? "")")
    }
}
