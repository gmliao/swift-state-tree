import Testing
@testable import SwiftStateTree

@StateNodeBuilder
private struct BaselineTestState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.broadcast) var monsters: [Int: Int] = [:]
    @Sync(.perPlayerSlice()) var inventories: [PlayerID: [String]] = [:]
    init() {}
}

private func setValues(_ patches: [StatePatch]) -> [String: SnapshotValue] {
    var out: [String: SnapshotValue] = [:]
    for patch in patches {
        if case .set(let value) = patch.operation {
            out[patch.path] = value
        }
    }
    return out
}

@Test("empty baseline returns a set patch for every broadcast field; cache holds the previous view afterward")
func testEmptyBaselineBroadcast() throws {
    var engine = SyncEngine()
    var state = BaselineTestState()
    state.tick = 3
    state.monsters = [1: 10, 2: 20]

    let snapshot = try engine.extractBroadcastSnapshot(from: state, mode: .all)

    // First call with .empty must already return full content (no "seed and return []").
    let first = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, onlyPaths: nil, mode: .all, baseline: .empty)
    let firstSets = setValues(first)
    #expect(firstSets["/tick"] == .int(3))
    #expect(firstSets["/monsters"] != nil)
    #expect(first.allSatisfy { if case .set = $0.operation { return true } else { return false } })

    // Second identical call must return the same full content: cache was not written.
    let second = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, onlyPaths: nil, mode: .all, baseline: .empty)
    #expect(setValues(second) == firstSets)

    // The cache now holds the previous full snapshot (replacement semantics), rather than being
    // empty: a subsequent .cached call diffs against it like the normal delta path would.
    state.tick = 4
    let mutatedSnapshot = try engine.extractBroadcastSnapshot(from: state, mode: .all)
    let cachedDiff = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: mutatedSnapshot, onlyPaths: nil, mode: .all, baseline: .cached)
    #expect(setValues(cachedDiff) == ["/tick": .int(4)])
}

@Test("empty baseline on per-player update returns diff with every per-player field; cache holds the previous view afterward")
func testEmptyBaselinePerPlayer() throws {
    var engine = SyncEngine()
    let alice = PlayerID("alice")
    var state = BaselineTestState()
    state.inventories[alice] = ["sword"]

    let perPlayer = try engine.extractPerPlayerSnapshot(for: alice, from: state, mode: .all)
    engine.markFirstSyncReceived(for: alice)

    let update = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: perPlayer, perPlayerMode: .all, onlyPaths: nil, baseline: .empty)
    guard case .diff(let patches) = update else {
        Issue.record("expected .diff, got \(update)")
        return
    }
    #expect(setValues(patches)["/inventories"] != nil)

    // Repeat: identical output expected from .empty baseline (always returns full view without cache access).
    let again = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: perPlayer, perPlayerMode: .all, onlyPaths: nil, baseline: .empty)
    #expect(again == update)

    // The cache now holds the previous per-player snapshot (replacement semantics), rather than
    // being empty: a subsequent .cached call diffs against it like the normal delta path would.
    state.inventories[alice] = ["sword", "shield"]
    let mutatedPerPlayer = try engine.extractPerPlayerSnapshot(for: alice, from: state, mode: .all)
    let cachedUpdate = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: mutatedPerPlayer, perPlayerMode: .all, onlyPaths: nil, baseline: .cached)
    guard case .diff(let cachedPatches) = cachedUpdate else {
        Issue.record("expected .diff, got \(cachedUpdate)")
        return
    }
    // Both old and new snapshots have the "inventories" key, so the diff recurses into the
    // per-player object and reports the change at "/inventories/alice" rather than replacing the
    // whole top-level key (see the "added" case in `testEmptyBaselineBroadcast`/the vanished-field
    // test below, where one side lacks the key entirely and the whole value is set/deleted).
    #expect(cachedPatches.contains { $0.path.hasPrefix("/inventories") })
}

@Test("empty baseline emits a delete for a per-player field that vanishes from the view")
func testEmptyBaselineEmitsDeleteForVanishedPerPlayerField() throws {
    var engine = SyncEngine()
    let alice = PlayerID("alice")
    var state = BaselineTestState()
    state.inventories[alice] = ["sword"]

    // First .empty call: alice's slice is present, so "inventories" is a `.set`.
    let present = try engine.extractPerPlayerSnapshot(for: alice, from: state, mode: .all)
    let firstUpdate = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: present, perPlayerMode: .all, onlyPaths: nil, baseline: .empty)
    guard case .diff(let firstPatches) = firstUpdate else {
        Issue.record("expected .diff, got \(firstUpdate)")
        return
    }
    #expect(setValues(firstPatches)["/inventories"] != nil)

    // Alice's entry disappears from the underlying state (e.g. the conditional per-player field
    // is removed for a still-connected player). The new snapshot has no "inventories" key at all,
    // so the diff against an empty snapshot alone would produce neither `.set` nor `.delete` — the
    // fix must emit `.delete` by comparing against the cached previous view instead.
    state.inventories.removeValue(forKey: alice)
    let absent = try engine.extractPerPlayerSnapshot(for: alice, from: state, mode: .all)
    #expect(absent.values["inventories"] == nil)

    let secondUpdate = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: absent, perPlayerMode: .all, onlyPaths: nil, baseline: .empty)
    guard case .diff(let secondPatches) = secondUpdate else {
        Issue.record("expected .diff, got \(secondUpdate)")
        return
    }
    #expect(secondPatches.contains(StatePatch(path: "/inventories", operation: .delete)))
    #expect(setValues(secondPatches)["/inventories"] == nil)

    // A third .empty call with the same (still absent) state: the cache was already replaced with
    // the "inventories"-less snapshot, so there is nothing left to report as vanished.
    let thirdUpdate = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: absent, perPlayerMode: .all, onlyPaths: nil, baseline: .empty)
    #expect(thirdUpdate == .noChange)
}

@Test("cached baseline is unchanged: first call seeds, second call diffs")
func testCachedBaselineUnchanged() throws {
    var engine = SyncEngine()
    var state = BaselineTestState()
    state.tick = 1
    let s1 = try engine.extractBroadcastSnapshot(from: state, mode: .all)
    #expect(engine.computeBroadcastDiffFromSnapshot(currentBroadcast: s1, onlyPaths: nil, mode: .all, baseline: .cached).isEmpty)
    state.tick = 2
    let s2 = try engine.extractBroadcastSnapshot(from: state, mode: .all)
    let diff = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: s2, onlyPaths: nil, mode: .all, baseline: .cached)
    #expect(setValues(diff) == ["/tick": .int(2)])
}
