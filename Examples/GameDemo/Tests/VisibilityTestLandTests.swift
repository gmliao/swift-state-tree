import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeDeterministicMath
@testable import GameContent

@Suite("Visibility test land knobs")
struct VisibilityTestLandTests {
    @Test("Settings come from the environment, clamped, with defaults; an unknown filter throws")
    func settingsFromEnvironment() throws {
        #expect(try VisibilityTestSettings.fromEnvironment([:]) == VisibilityTestSettings())
        #expect(VisibilityTestSettings() == VisibilityTestSettings(entityCount: 40, viewRadius: 15, filter: .radius))
        let settings = try VisibilityTestSettings.fromEnvironment([
            VisibilityTestEnvKeys.entityCount: "640",
            VisibilityTestEnvKeys.viewRadius: "8.5",
            VisibilityTestEnvKeys.filter: "all",
        ])
        #expect(settings == VisibilityTestSettings(entityCount: 640, viewRadius: 8.5, filter: .all))
        // Out of range or malformed: refused, never clamped into another cell.
        for bad in [
            [VisibilityTestEnvKeys.entityCount: "0"], [VisibilityTestEnvKeys.entityCount: "5000"],
            [VisibilityTestEnvKeys.entityCount: "forty"], [VisibilityTestEnvKeys.viewRadius: "1000"],
            [VisibilityTestEnvKeys.viewRadius: "0.5"], [VisibilityTestEnvKeys.filter: "none"],
        ] {
            #expect(throws: VisibilityTestSettingsError.self) { _ = try VisibilityTestSettings.fromEnvironment(bad) }
        }
        let edges = try VisibilityTestSettings.fromEnvironment([VisibilityTestEnvKeys.entityCount: "4096", VisibilityTestEnvKeys.viewRadius: "200"])
        #expect(edges.entityCount == 4096 && edges.viewRadius == 200)
    }

    @Test("The first four slots keep their positions; up to 16 viewers get distinct positions")
    func viewerSlots() {
        for slot in 0..<4 {
            #expect(VisibilityTestConfig.viewerPosition(slot: slot) == VisibilityTestConfig.viewerSlots[slot])
        }
        let positions = (0..<VisibilityTestConfig.maxPlayers).map { VisibilityTestConfig.viewerPosition(slot: $0) }
        #expect(Set(positions.map { "\($0.v.x),\($0.v.y)" }).count == VisibilityTestConfig.maxPlayers)
        #expect(VisibilityTestConfig.viewerPosition(slot: 4) == Position2(x: 12.5, y: 12.5))
        #expect(VisibilityTestConfig.viewerPosition(slot: 4 + 16) == VisibilityTestConfig.viewerPosition(slot: 4))
    }

    @Test("Spawn: the first 100 entities start where they always did; 640 entities start apart")
    func spawn() {
        var state = VisibilityTestState()
        VisibilityTest.spawnEntitiesIfNeeded(&state, settings: VisibilityTestSettings(entityCount: 640))
        #expect(state.entities.count == 640)
        // The positions before the offset: (index * 37 % 100, index * 61 % 100).
        for index in [0, 1, 39, 99] {
            #expect(state.entities["e\(index)"]?.position == Position2(x: Float(index * 37 % 100), y: Float(index * 61 % 100)))
        }
        let starts = Set(state.entities.values.map { "\($0.position.v.x),\($0.position.v.y)" })
        #expect(starts.count == 640)
        var most = VisibilityTestState()
        VisibilityTest.spawnEntitiesIfNeeded(&most, settings: VisibilityTestSettings(entityCount: 4096))
        #expect(Set(most.entities.values.map(\.position.v.x)).count == 4096)
        #expect(most.entities.values.allSatisfy { $0.position.v.x <= Position2(x: 100, y: 0).v.x && $0.position.v.y <= Position2(x: 0, y: 100).v.y })

        var defaults = VisibilityTestState()
        VisibilityTest.spawnEntitiesIfNeeded(&defaults, settings: VisibilityTestSettings())
        #expect(defaults.entities.count == 40)
    }

    @Test("Visibility is inclusive at the radius and excludes one quantum past it")
    func radiusBoundary() {
        let settings = VisibilityTestSettings(entityCount: 1, viewRadius: 15)
        let viewer = PlayerID("p0")
        var state = VisibilityTestState()
        VisibilityTest.spawnEntitiesIfNeeded(&state, settings: settings)
        state.viewers[viewer] = Viewer(slot: 0, position: Position2(x: 20, y: 20))

        state.entities["e0"]?.position = Position2(x: 35, y: 20)
        VisibilityTest.updateVisibility(&state, settings: settings)
        #expect(state.entities["e0"]?.visibleTo == [viewer])

        // One quantum (0.001) past the radius.
        state.entities["e0"]?.position = Position2(x: 35.001, y: 20)
        #expect(state.entities["e0"]?.position.v.x == Position2(x: 35, y: 20).v.x + 1)
        VisibilityTest.updateVisibility(&state, settings: settings)
        #expect(state.entities["e0"]?.visibleTo == [])
        #expect(state.viewEntries == 1 && state.viewExits == 1)

        // A smaller radius from the settings applies.
        state.entities["e0"]?.position = Position2(x: 30, y: 20)
        VisibilityTest.updateVisibility(&state, settings: VisibilityTestSettings(entityCount: 1, viewRadius: 8))
        #expect(state.entities["e0"]?.visibleTo == [])
    }

    @Test("Filter radius sends only the entities a player sees; filter all sends every entity")
    func filters() {
        let a = PlayerID("a"), b = PlayerID("b")
        var seen = VisibleEntity()
        seen.id = "e0"
        seen.visibleTo = [a]
        var unseen = VisibleEntity()
        unseen.id = "e1"
        let entities = ["e0": seen, "e1": unseen]
        #expect(Set(VisibilityTest.entities(entities, sentTo: a, filter: .radius).keys) == ["e0"])
        #expect(VisibilityTest.entities(entities, sentTo: b, filter: .radius).isEmpty)
        #expect(Set(VisibilityTest.entities(entities, sentTo: b, filter: .all).keys) == ["e0", "e1"])
    }

    @Test("A record's settings are checked against the replay's; a record without them replays only with the defaults")
    func recordMismatch() {
        let settings = VisibilityTestSettings(entityCount: 160, viewRadius: 8, filter: .all)
        #expect(settings.recordMismatch(settings.recordMetadata) == nil)
        // A record without settings replays only with the defaults.
        #expect(VisibilityTestSettings().recordMismatch([:]) == nil)
        #expect(settings.recordMismatch([:])?.contains("defaults") == true)
        #expect(settings.recordMismatch([VisibilityTestEnvKeys.filter: "all"])?.contains(VisibilityTestEnvKeys.entityCount) == true)
        let other = VisibilityTestSettings(entityCount: 160, viewRadius: 15, filter: .all)
        let mismatch = settings.recordMismatch(other.recordMetadata)
        #expect(mismatch?.contains(VisibilityTestEnvKeys.viewRadius) == true)
        #expect(mismatch?.contains(VisibilityTestEnvKeys.entityCount) == false)
        #expect(VisibilityTestSettings().recordMismatch(VisibilityTestSettings(filter: .all).recordMetadata)?.contains(VisibilityTestEnvKeys.filter) == true)
    }
}
