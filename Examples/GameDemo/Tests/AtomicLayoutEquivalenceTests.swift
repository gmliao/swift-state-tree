import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeDeterministicMath
@testable import GameContent

/// The atomic values of every GameDemo land are the same under the declaration
/// (`AtomicSnapshotValue`, through `AtomicLayoutTable`) as under the shape heuristic it replaced,
/// on populated states (every collection has at least one entry, every optional atomic value is
/// set once and nil once). The table's patterns are also pinned, so a change to them is visible.
@Suite("Atomic layout equivalence (GameDemo lands)")
struct AtomicLayoutEquivalenceTests {
    // MARK: - Fixtures

    static func heroDefenseState() -> HeroDefenseState {
        var state = HeroDefenseState()
        var moving = PlayerState()
        moving.position = Position2(x: 64, y: 36)
        moving.rotation = Angle(degrees: 30)
        moving.targetPosition = Position2(x: 70, y: 40)
        state.players[PlayerID("p1")] = moving
        var idle = PlayerState()
        idle.position = Position2(x: 10, y: 12)
        state.players[PlayerID("p2")] = idle

        var monster = MonsterState()
        monster.id = 7
        monster.position = Position2(x: 80, y: 40)
        monster.rotation = Angle(degrees: 90)
        state.monsters[7] = monster

        var turret = TurretState()
        turret.id = 3
        turret.position = Position2(x: 66, y: 37)
        turret.rotation = Angle(degrees: 45)
        turret.ownerID = PlayerID("p1")
        state.turrets[3] = turret
        return state
    }

    static func visibilityState() -> VisibilityTestState {
        var state = VisibilityTestState()
        var entity = VisibleEntity()
        entity.id = "e1"
        entity.position = Position2(x: 5, y: 6)
        entity.step = IVec2(x: 1, y: 0)
        entity.visibleTo = [PlayerID("p1")]
        state.entities["e1"] = entity
        state.viewers[PlayerID("p1")] = Viewer(slot: 0, position: Position2(x: 1, y: 2))
        return state
    }

    // MARK: - Tests

    @Test("Hero Defense: the declared atomic paths equal the heuristic's on a populated state")
    func heroDefenseEquivalence() throws {
        let state = Self.heroDefenseState()
        let table = AtomicLayoutTable.forState(HeroDefenseState.self)
        try Self.expectEquivalent(state, table: table, players: [PlayerID("p1"), PlayerID("p2")])
        #expect(Set(table.patterns.keys) == [
            "base.position",
            "monsters.*.position", "monsters.*.rotation", "monsters.*.spawnPosition",
            "players.*.position", "players.*.rotation", "players.*.targetPosition",
            "turrets.*.position", "turrets.*.rotation",
        ])
    }

    @Test("Visibility test: the declared atomic paths equal the heuristic's on a populated state")
    func visibilityEquivalence() throws {
        let state = Self.visibilityState()
        let table = AtomicLayoutTable.forState(VisibilityTestState.self)
        try Self.expectEquivalent(state, table: table, players: [PlayerID("p1")])
        #expect(Set(table.patterns.keys) == [
            "entities.*.position", "entities.*.step", "viewers.*.position",
        ])
    }

    @Test("No registration needed: a standalone engine diffs a Position2 change as one patch")
    func standaloneEngineDiffsPositionAsOnePatch() throws {
        var engine = SyncEngine(for: HeroDefenseState.self)
        var state = Self.heroDefenseState()
        let player = PlayerID("p1")
        _ = try engine.generateDiff(for: player, from: state)
        state.players[player]?.position = Position2(x: 65, y: 36)
        let update = try engine.generateDiff(for: player, from: state)
        guard case .diff(let patches) = update else {
            Issue.record("expected .diff, got \(update)")
            return
        }
        #expect(patches.map(\.path) == ["/players/p1/position"])
    }

    // MARK: - Comparison

    /// Every object in each view of `state` is atomic under the heuristic exactly when its path
    /// matches one of the table's patterns; and each view has at least one atomic value.
    static func expectEquivalent<S: StateNodeProtocol>(
        _ state: S, table: AtomicLayoutTable, players: [PlayerID]
    ) throws {
        let engine = SyncEngine(for: S.self)
        var views: [(String, StateSnapshot)] = [("broadcast", try engine.snapshot(for: nil, from: state, mode: .all))]
        for player in players {
            views.append((player.rawValue, try engine.snapshot(for: player, from: state, mode: .all)))
        }
        let patterns = table.patterns.keys.map { $0.split(separator: ".").map(String.init) }
        for (name, view) in views {
            var heuristic: Set<String> = []
            var declared: Set<String> = []
            for (key, value) in view.values {
                collect(value, path: [key], patterns: patterns, heuristic: &heuristic, declared: &declared)
            }
            #expect(heuristic == declared, "view \(name): heuristic \(heuristic.sorted()), declared \(declared.sorted())")
            #expect(!declared.isEmpty, "view \(name) has no atomic value, so the comparison is trivial")
        }
    }

    private static func collect(
        _ value: SnapshotValue, path: [String], patterns: [[String]],
        heuristic: inout Set<String>, declared: inout Set<String>
    ) {
        guard case .object(let object) = value else { return }
        let isDeclared = patterns.contains { pattern in
            pattern.count == path.count && zip(pattern, path).allSatisfy { $0 == "*" || $0 == $1 }
        }
        let isHeuristic = shapeHeuristic(object, object)
        let joined = path.joined(separator: ".")
        if isDeclared { declared.insert(joined) }
        if isHeuristic { heuristic.insert(joined) }
        // Both stop at an atomic value, as the diff does.
        if isDeclared || isHeuristic { return }
        for (key, child) in object {
            collect(child, path: path + [key], patterns: patterns, heuristic: &heuristic, declared: &declared)
        }
    }

    /// The shape heuristic `SyncEngine` used before atomic values were declared, kept verbatim.
    private static func shapeHeuristic(_ oldObj: [String: SnapshotValue], _ newObj: [String: SnapshotValue]) -> Bool {
        let allKeys = Set(oldObj.keys).union(Set(newObj.keys))
        if allKeys == ["x", "y"] {
            if case .int = oldObj["x"], case .int = oldObj["y"],
               case .int = newObj["x"], case .int = newObj["y"] {
                return true
            }
        }
        if allKeys == ["x", "y", "z"] {
            if case .int = oldObj["x"], case .int = oldObj["y"], case .int = oldObj["z"],
               case .int = newObj["x"], case .int = newObj["y"], case .int = newObj["z"] {
                return true
            }
        }
        if allKeys == ["degrees"] {
            if case .int = oldObj["degrees"], case .int = newObj["degrees"] {
                return true
            }
        }
        if allKeys == ["v"] {
            if case .object(let oldV) = oldObj["v"],
               case .object(let newV) = newObj["v"] {
                let vKeys = Set(oldV.keys).union(Set(newV.keys))
                if vKeys == ["x", "y"] {
                    if case .int = oldV["x"], case .int = oldV["y"],
                       case .int = newV["x"], case .int = newV["y"] {
                        return true
                    }
                }
            }
        }
        return false
    }
}
