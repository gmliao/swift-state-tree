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

    @Test("The broadcast-view hash of a fixed state is pinned (records 2.3)")
    func pinnedBroadcastViewHash() {
        #expect(ReevaluationEngine.calculateBroadcastViewHash(Self.fixedState()) == "58d147d2cbc90616")
    }

    @Test("The full-state hash of a fixed state is pinned (records 2.4)")
    func pinnedFullStateHash() {
        #expect(ReevaluationEngine.calculateStateHash(Self.fixedState()) == "252ba74117aa4c9c")
    }

    @Test("Hero Defense has the shape #175 changed; visibility-test's map is per-player, so it does not")
    func affectedLands() {
        #expect(ReevaluationRecordVersion.hashChangedByNestedNodePolicies(HeroDefenseState.self))
        // `entities` is `.perPlayer`: not in the broadcast view the hash covers.
        #expect(!ReevaluationRecordVersion.hashChangedByNestedNodePolicies(VisibilityTestState.self))
    }

    @Test("Visibility-test's full-state hash covers the per-player map and server-only entity fields")
    func visibilityFullStateHash() {
        var state = VisibilityTestState()
        var entity = VisibleEntity()
        entity.id = "e1"
        entity.position = Position2(x: 3, y: 4)
        entity.step = IVec2(x: 1, y: -1)
        entity.visibleTo = [PlayerID("p1")]
        state.entities["e1"] = entity
        #expect(ReevaluationEngine.calculateStateHash(state) == "48a94b4939ae2ee8")
        var changed = state
        changed.entities["e1"]?.step = IVec2(x: 2, y: -1)
        #expect(ReevaluationEngine.calculateStateHash(changed) != ReevaluationEngine.calculateStateHash(state))
        #expect(ReevaluationEngine.calculateBroadcastViewHash(changed) == ReevaluationEngine.calculateBroadcastViewHash(state))
    }

    @Test("Every server-only field enters the full-state hash, none the broadcast-view hash")
    func serverOnlyFields() {
        let base = Self.fixedState()
        let mutations: [(String, (inout HeroDefenseState) -> Void)] = [
            ("player lastFireTick", { $0.players[PlayerID("p1")]?.lastFireTick = 1_000 }),
            ("monster reward", { $0.monsters[7]?.reward = 1_000 }),
            ("monster pathProgress", { $0.monsters[7]?.pathProgress += 0.5 }),
            ("turret lastFireTick", { $0.turrets[3]?.lastFireTick = 1_000 }),
            ("nextMonsterID", { $0.nextMonsterID = 1_000 }),
        ]
        for (name, mutate) in mutations {
            var changed = base
            mutate(&changed)
            #expect(ReevaluationEngine.calculateStateHash(changed) != ReevaluationEngine.calculateStateHash(base), "\(name)")
            #expect(ReevaluationEngine.calculateBroadcastViewHash(changed) == ReevaluationEngine.calculateBroadcastViewHash(base), "\(name)")
        }
    }
}
