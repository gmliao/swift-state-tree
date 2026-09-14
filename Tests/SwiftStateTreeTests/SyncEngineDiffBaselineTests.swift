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

@Test("empty baseline returns a set patch for every broadcast field and never seeds the cache")
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

    // A subsequent .cached call behaves like a first call (cache still empty): seeds and returns [].
    let cachedFirst = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, onlyPaths: nil, mode: .all, baseline: .cached)
    #expect(cachedFirst.isEmpty)
}

@Test("empty baseline on per-player update returns diff with every per-player field, cache untouched")
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

    // A subsequent .cached call behaves like a first call (cache still empty): seeds and returns .noChange.
    let cachedFirst = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: perPlayer, perPlayerMode: .all, onlyPaths: nil, baseline: .cached)
    #expect(cachedFirst == .noChange)
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
