import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeDeterministicMath
@testable import GameContent

/// Pins the recorded state hash of a fixed Hero Defense state. The hash covers the broadcast view
/// (`snapshot(for: nil)`); since #175 that view leaves out the server-only fields of nested
/// nodes (`players.*.lastFireTick`, monster `reward`/`pathProgress`/`spawnPosition`, turret
/// `lastFireTick`). A change of this value breaks every recording's hashes: bump
/// `ReevaluationRecordVersion` with it.
@Suite("Hero Defense state hash pin")
struct HeroDefenseStateHashPinTests {
    static func fixedState() -> HeroDefenseState {
        var state = HeroDefenseState()
        var player = PlayerState()
        player.position = Position2(x: 64, y: 36)
        player.health = 111
        player.lastFireTick = 42
        state.players[PlayerID("p1")] = player

        var monster = MonsterState()
        monster.id = 7
        monster.position = Position2(x: 80, y: 40)
        monster.reward = 9
        state.monsters[7] = monster

        var turret = TurretState()
        turret.id = 3
        turret.position = Position2(x: 66, y: 37)
        turret.ownerID = PlayerID("p1")
        turret.lastFireTick = 40
        state.turrets[3] = turret

        state.score = 55
        state.nextMonsterID = 8
        return state
    }

    @Test("The recorded state hash of a fixed state is pinned (record 2.3)")
    func pinnedHash() {
        #expect(ReevaluationEngine.calculateStateHash(Self.fixedState()) == "58d147d2cbc90616")
    }

    @Test("Server-only fields of nested nodes do not enter the hash")
    func serverOnlyFieldsDoNotEnterHash() {
        var changed = Self.fixedState()
        changed.players[PlayerID("p1")]?.lastFireTick = 1_000
        changed.monsters[7]?.reward = 1_000
        changed.turrets[3]?.lastFireTick = 1_000
        changed.nextMonsterID = 1_000
        #expect(ReevaluationEngine.calculateStateHash(changed) == ReevaluationEngine.calculateStateHash(Self.fixedState()))
    }
}
