import Testing
import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeReevaluationMonitor
@testable import GameContent

@Suite("HeroDefenseReplayStateParityTests")
struct HeroDefenseReplayStateParityTests {
    @Test("HeroDefenseState satisfies StateFromSnapshotDecodable for GenericReplayLand")
    func heroDefenseStateConformsToStateFromSnapshotDecodable() {
        requireReplayDecodable(HeroDefenseState.self)
    }

    @Test("HeroDefenseState decodes broadcast snapshot with entities")
    func heroDefenseStateDecodesBroadcastSnapshotWithEntities() throws {
        var original = HeroDefenseState()

        var player = PlayerState()
        player.position = Position2(x: 64, y: 36)
        player.health = 111
        original.players[PlayerID("p1")] = player

        var monster = MonsterState()
        monster.id = 7
        monster.position = Position2(x: 80, y: 40)
        original.monsters[7] = monster

        var turret = TurretState()
        turret.id = 3
        turret.position = Position2(x: 66, y: 37)
        turret.ownerID = PlayerID("p1")
        original.turrets[3] = turret

        original.score = 55

        let snapshot = try original.broadcastSnapshot(dirtyFields: nil)
        let decoded = try HeroDefenseState(fromBroadcastSnapshot: snapshot)

        #expect(decoded.players.count == 1)
        #expect(decoded.monsters.count == 1)
        #expect(decoded.turrets.count == 1)
        #expect(decoded.score == 55)
        #expect(decoded.players[PlayerID("p1")]?.health == 111)
        #expect(decoded.monsters[7]?.id == 7)
        #expect(decoded.turrets[3]?.ownerID == PlayerID("p1"))
    }

    @Test("GenericReplayLand built from HeroDefense preserves identity and access-control")
    func genericReplayLandBuiltFromHeroDefensePreservesIdentityAndAccessControl() {
        let liveLand = HeroDefense.makeLand()
        let replayLand = GenericReplayLand<HeroDefenseState>.makeLand(basedOn: liveLand)

        #expect(replayLand.id == liveLand.id)
        #expect(replayLand.config.allowPublic == liveLand.config.allowPublic)
        #expect(replayLand.config.maxPlayers == liveLand.config.maxPlayers)
        #expect(replayLand.lifetimeHandlers.tickInterval == liveLand.lifetimeHandlers.tickInterval)
    }

    @Test("HeroDefenseReplayProjector emits state object with non-empty entity collections")
    func heroDefenseReplayProjectorEmitsStateObjectWithEntityCollections() throws {
        let json = #"{"values":{"players":{"p1":{"health":100,"maxHealth":100,"position":{"v":{"x":64000,"y":36000}},"rotation":{"degrees":0},"targetPosition":null,"weaponLevel":0,"resources":0}},"monsters":{"1":{"id":1,"health":10,"maxHealth":10,"position":{"v":{"x":65000,"y":36500}},"rotation":{"degrees":1000}}},"turrets":{"2":{"id":2,"position":{"v":{"x":64500,"y":36200}},"rotation":{"degrees":0},"level":1,"ownerID":"p1"}},"base":{"position":{"v":{"x":64000,"y":36000}},"radius":3,"health":100,"maxHealth":100},"score":9}}"#

        let result = ReevaluationStepResult(
            tickId: 1,
            stateHash: "h1",
            recordedHash: "h1",
            isMatch: true,
            actualState: AnyCodable(json),
            emittedServerEvents: []
        )

        let projected = try HeroDefenseReplayProjector().project(result)

        #expect(projected.tickID == 1)
        #expect(entityCount(projected.stateObject["players"]) == 1)
        #expect(entityCount(projected.stateObject["monsters"]) == 1)
        #expect(entityCount(projected.stateObject["turrets"]) == 1)
    }

    @Test("HeroDefenseState decodes first ConcreteReevaluationRunner snapshot from fixture record")
    func heroDefenseStateDecodesRunnerSnapshotFixture() async throws {
        let recordPath = fixtureRecordPath("3-hero-defense.json")
        #expect(FileManager.default.fileExists(atPath: recordPath))

        var services = LandServices()
        services.register(
            GameConfigProviderService(provider: DefaultGameConfigProvider()),
            as: GameConfigProviderService.self
        )

        let runner = try await ConcreteReevaluationRunner(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            recordFilePath: recordPath,
            services: services
        )

        guard let first = try await runner.step() else {
            Issue.record("Expected at least one replay tick in fixture record")
            return
        }

        guard let snapshot = decodeReplayState(StateSnapshot.self, from: first.actualState) else {
            Issue.record("Expected first replay tick to include decodable StateSnapshot")
            return
        }

        let decoded = try HeroDefenseState(fromBroadcastSnapshot: snapshot)
        #expect(!decoded.players.isEmpty)
        #expect(!decoded.monsters.isEmpty)
    }
}

private func requireReplayDecodable<T: StateFromSnapshotDecodable>(_: T.Type) {}

private func entityCount(_ value: AnyCodable?) -> Int {
    guard let value else {
        return 0
    }

    if let dict = value.base as? [String: Any] {
        return dict.count
    }

    if let dict = value.base as? [String: AnyCodable] {
        return dict.count
    }

    return 0
}

private func fixtureRecordPath(_ fileName: String) -> String {
    let thisFile = URL(fileURLWithPath: #filePath)
    let gameDemoRoot = thisFile
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // GameDemo
    return gameDemoRoot
        .appendingPathComponent("reevaluation-records")
        .appendingPathComponent(fileName)
        .path
}
