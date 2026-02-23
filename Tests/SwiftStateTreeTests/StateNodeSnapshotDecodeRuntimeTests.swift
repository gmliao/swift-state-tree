import Testing
@testable import SwiftStateTree

// Minimal test state — only Int, String, Bool, and [String: Int] (Phase 1 types)
// Uses @StateNodeBuilder which should auto-generate StateFromSnapshotDecodable conformance
// including init(fromBroadcastSnapshot:).
@StateNodeBuilder
struct MockReplayState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var name: String = ""
    @Sync(.broadcast) var active: Bool = false
    @Sync(.broadcast) var tags: [String: Int] = [:]
    @Sync(.serverOnly) var internalCounter: Int = 0  // NOT in broadcast snapshot
}

@Suite("StateNode fromBroadcastSnapshot runtime")
struct StateNodeSnapshotDecodeRuntimeTests {

    @Test("decodes primitive values correctly")
    func decodesPrimitiveValues() throws {
        let snapshot = StateSnapshot(values: [
            "score": .int(42),
            "name": .string("test-player"),
            "active": .bool(true)
        ])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.score == 42)
        #expect(state.name == "test-player")
        #expect(state.active == true)
    }

    @Test("missing snapshot fields keep default values")
    func missingFieldsKeepDefaults() throws {
        let snapshot = StateSnapshot(values: ["score": .int(99)])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.score == 99)
        #expect(state.name == "")
        #expect(state.active == false)
    }

    @Test("dirty flags are set for all decoded fields")
    func dirtyFlagsSetAfterDecode() throws {
        let snapshot = StateSnapshot(values: [
            "score": .int(10),
            "name": .string("player"),
            "active": .bool(false)
        ])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.isDirty() == true)
        let dirty = state.getDirtyFields()
        #expect(dirty.contains("score"))
        #expect(dirty.contains("name"))
        #expect(dirty.contains("active"))
    }

    @Test("fields absent from snapshot are NOT dirty")
    func absentFieldsNotDirty() throws {
        let snapshot = StateSnapshot(values: ["score": .int(5)])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        let dirty = state.getDirtyFields()
        #expect(dirty.contains("score"))
        #expect(!dirty.contains("name"))
        #expect(!dirty.contains("active"))
    }

    @Test("[String: Int] dictionary decodes correctly")
    func stringIntDictionaryDecode() throws {
        let snapshot = StateSnapshot(values: [
            "tags": .object(["kills": .int(3), "deaths": .int(1)])
        ])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.tags["kills"] == 3)
        #expect(state.tags["deaths"] == 1)
    }

    @Test("broadcastSnapshot round-trip preserves values")
    func broadcastSnapshotRoundTrip() throws {
        var original = MockReplayState()
        original.score = 77
        original.name = "roundtrip"
        original.active = true
        original.tags = ["x": 5]

        let snapshot = try original.broadcastSnapshot(dirtyFields: nil)
        let decoded = try MockReplayState(fromBroadcastSnapshot: snapshot)

        #expect(decoded.score == 77)
        #expect(decoded.name == "roundtrip")
        #expect(decoded.active == true)
        #expect(decoded.tags["x"] == 5)
    }

    @Test("serverOnly field excluded from broadcastSnapshot")
    func serverOnlyFieldExcluded() throws {
        var original = MockReplayState()
        original.internalCounter = 999
        let snapshot = try original.broadcastSnapshot(dirtyFields: nil)
        #expect(snapshot.values["internalCounter"] == nil)
        let decoded = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(decoded.internalCounter == 0)
    }
}
