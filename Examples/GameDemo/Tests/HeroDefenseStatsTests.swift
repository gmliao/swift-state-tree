import Foundation
import Testing
import SwiftStateTree
@testable import GameContent

@Suite("Hero Defense stats")
struct HeroDefenseStatsTests {
    @Test("The recorder keeps each land's latest sample; taking the window empties it")
    func recorder() {
        let recorder = HeroDefenseStatsRecorder()
        recorder.note(landID: "a", HeroDefenseLandSample(tick: 1, monsters: 1, baseHealth: 100, players: 5))
        recorder.note(landID: "b", HeroDefenseLandSample(tick: 7, monsters: 2, baseHealth: 100, players: 4))
        recorder.note(landID: "a", HeroDefenseLandSample(tick: 2, monsters: 3, baseHealth: 99, players: 5))
        #expect(recorder.takeWindow() == [
            "a": HeroDefenseLandSample(tick: 2, monsters: 3, baseHealth: 99, players: 5),
            "b": HeroDefenseLandSample(tick: 7, monsters: 2, baseHealth: 100, players: 4),
        ])
        #expect(recorder.takeWindow().isEmpty)
    }

    @Test("The land notes its tick, monsters, base health and players; without a recorder the state is the same")
    func land() async throws {
        func run(_ stats: HeroDefenseStatsRecorder?) async throws -> (HeroDefenseState, String) {
            var services = LandServices()
            services.register(GameConfigProviderService(provider: DefaultGameConfigProvider()), as: GameConfigProviderService.self)
            if let stats {
                services.register(stats, as: HeroDefenseStatsRecorder.self)
            }
            let keeper = LandKeeper<HeroDefenseState>(
                definition: HeroDefense.makeLand(),
                initialState: HeroDefenseState(),
                services: services,
                autoStartLoops: false
            )
            await keeper.setLandID("hero-defense:stats")
            try await keeper.join(playerID: PlayerID("alice"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
            // Past the first spawns (every 30 ticks at first).
            for _ in 0..<95 { await keeper.stepTickOnce() }
            let state = await keeper.currentState()
            return (state, ReevaluationEngine.calculateStateHashAndSnapshot(state).0)
        }
        let stats = HeroDefenseStatsRecorder()
        let (noted, notedHash) = try await run(stats)
        let window = stats.takeWindow()
        let sample = try #require(window["hero-defense:stats"])
        #expect(window.count == 1)
        #expect(sample == HeroDefenseLandSample(tick: 94, monsters: noted.monsters.count,
                                                baseHealth: noted.base.health, players: noted.players.count))
        #expect(sample.monsters > 0 && sample.players == 1)
        // Re-evaluation registers no recorder: the same inputs give the same state.
        let (plain, plainHash) = try await run(nil)
        #expect(plainHash == notedHash)
        #expect(plain.monsters.count == noted.monsters.count && plain.nextMonsterID == noted.nextMonsterID)
    }

    @Test("The writer is off without a path and refuses a bad interval")
    func writerSettings() throws {
        #expect(try HeroDefenseStatsWriter.startFromEnvironment([:]) == nil)
        #expect(throws: HeroDefenseStatsSettingsError.self) {
            _ = try HeroDefenseStatsWriter.startFromEnvironment([HeroDefenseStatsEnvKeys.path: "/dev/null", HeroDefenseStatsEnvKeys.intervalMs: "50"])
        }
    }

    @Test("A line carries its window and the lands by ID")
    func line() throws {
        let line = HeroDefenseStatsLine(fromTs: 1_000, ts: 2_000,
                                        lands: ["l1": HeroDefenseLandSample(tick: 20, monsters: 3, baseHealth: 100, players: 5)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(line), as: UTF8.self)
        #expect(text == #"{"fromTs":1000,"lands":{"l1":{"baseHealth":100,"monsters":3,"players":5,"tick":20}},"ts":2000,"writeFailures":0}"#)
        #expect(try JSONDecoder().decode(HeroDefenseStatsLine.self, from: Data(text.utf8)) == line)
    }
}
