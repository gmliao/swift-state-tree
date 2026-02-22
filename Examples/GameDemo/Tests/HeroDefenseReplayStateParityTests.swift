import Testing
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeReevaluationMonitor
@testable import GameContent

@Suite("HeroDefenseReplayStateParityTests")
struct HeroDefenseReplayStateParityTests {
    @Test("Replay land uses HeroDefenseState as the state definition")
    func replayLandUsesLiveStateDefinition() {
        let replayLand = GenericReplayLand.makeLand(landType: "hero-defense", stateType: HeroDefenseState.self)

        #expect(replayLand.stateType == HeroDefenseState.self)
    }

    @Test("Replay land registers ReplayTick server event")
    func replayLandRegistersReplayTickServerEvent() {
        let replayLand = GenericReplayLand.makeLand(landType: "hero-defense", stateType: HeroDefenseState.self)
        let eventNames = Set(replayLand.serverEventRegistry.registered.map { $0.eventName })

        #expect(eventNames.contains("ReplayTick"))
    }

    @Test("Live HeroDefense snapshot shape has no replay wrapper artifacts")
    func liveSnapshotShapeHasNoReplayWrapperArtifacts() throws {
        var replay = HeroDefenseState()
        var player = PlayerState()
        player.position = Position2(x: 10.0, y: 20.0)
        replay.players[PlayerID("p1")] = player

        var monster = MonsterState()
        monster.id = 1
        monster.position = Position2(x: 11.0, y: 22.0)
        replay.monsters[1] = monster

        var turret = TurretState()
        turret.id = 2
        turret.position = Position2(x: 30.0, y: 40.0)
        turret.ownerID = PlayerID("p1")
        replay.turrets[2] = turret

        replay.base.health = 88
        replay.base.maxHealth = 100
        replay.score = 123

        let snapshot = try replay.broadcastSnapshot(dirtyFields: nil)
        let playersValue = snapshot.values["players"]?.objectValue
        let playerP1 = playersValue?["p1"]?.objectValue
        let monstersValue = snapshot.values["monsters"]?.objectValue
        let monster1 = monstersValue?["1"]?.objectValue
        let turretsValue = snapshot.values["turrets"]?.objectValue
        let turret2 = turretsValue?["2"]?.objectValue
        let baseValue = snapshot.values["base"]?.objectValue
        let scoreValue = snapshot.values["score"]

        #expect(playersValue != nil)
        #expect(playerP1?["base"] == nil)
        #expect(playerP1?["position"] != nil)
        #expect(monstersValue != nil)
        #expect(monster1?["position"] != nil)
        #expect(turretsValue != nil)
        #expect(turret2?["position"] != nil)
        #expect(baseValue?["base"] == nil)
        #expect(baseValue?["health"]?.intValue == 88)
        #expect(scoreValue?.intValue == 123)
    }
}
