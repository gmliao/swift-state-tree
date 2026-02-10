// Tests/SwiftStateTreeTests/IncrementalVsDiffEquivalenceTests.swift
//
// Verifies that incremental sync (patch recording) and diff-based sync (snapshot comparison)
// produce identical StatePatch output for the same mutations. Equivalence is required so
// that we can use incremental as the sole path in production without runtime fallback;
// these tests are the guarantee.
//
// Coverage: ReactiveDictionary (single/multiple keys, update, delete, mixed set+delete),
// nested state with ReactiveDictionary, nested StateNode scalar fields (child.health, child.name),
// mixed dict + scalar, and no-mutation. All @Sync broadcast fields record patches via Sync.patchContext.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test state types (broadcast-only for simplicity)

@StateNodeBuilder
struct EquivalenceTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var items: ReactiveDictionary<String, Int> = ReactiveDictionary<String, Int>()
    
    @Sync(.broadcast)
    var score: Int = 0
    
    public init() {}
}

@StateNodeBuilder
struct NestedChildState: StateNodeProtocol {
    @Sync(.broadcast)
    var health: Int = 100
    
    @Sync(.broadcast)
    var name: String = ""
    
    public init() {}
}

@StateNodeBuilder
struct NestedParentState: StateNodeProtocol {
    @Sync(.broadcast)
    var units: ReactiveDictionary<String, Int> = ReactiveDictionary<String, Int>()
    
    @Sync(.broadcast)
    var child: NestedChildState = NestedChildState()
    
    public init() {}
}

// MARK: - Helpers

/// Normalize patches for comparison: sort by path so order doesn't matter.
func normalizedPatches(_ patches: [StatePatch]) -> [StatePatch] {
    patches.sorted { $0.path < $1.path }
}

/// Drop whole-object patches when a more specific (leaf) patch exists for the same subtree,
/// so incremental (which may record both /child and /child/health) matches diff (which only has /child/health).
func dropRedundantWholeObjectPatches(_ patches: [StatePatch]) -> [StatePatch] {
    let paths = Set(patches.map(\.path))
    return patches.filter { patch in
        let p = patch.path
        let hasMoreSpecific = paths.contains { other in other != p && other.hasPrefix(p + "/") }
        return !hasMoreSpecific
    }
}

func patchesEqual(_ incremental: [StatePatch], _ diff: [StatePatch]) -> Bool {
    let a = normalizedPatches(dropRedundantWholeObjectPatches(incremental))
    let b = normalizedPatches(diff)
    guard a.count == b.count else { return false }
    return zip(a, b).allSatisfy { $0.path == $1.path && $0.operation == $1.operation }
}

/// Set up state with patch recorder propagated, seed SyncEngine cache with current snapshot, then run mutation block.
/// Returns (incrementalPatches, diffPatches) for comparison.
func runEquivalenceTest(
    initialState: inout EquivalenceTestState,
    mutate: (inout EquivalenceTestState) -> Void
) throws -> (incremental: [StatePatch], diff: [StatePatch]) {
    let recorder = LandPatchRecorder()
    initialState._$parentPath = ""
    initialState._$patchRecorder = recorder
    initialState._$propagatePatchContext()
    
    var syncEngine = SyncEngine()
    let snapshotBefore = try syncEngine.extractBroadcastSnapshot(from: initialState, mode: .all)
    _ = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotBefore, onlyPaths: nil, mode: .all)
    
    mutate(&initialState)
    
    let incrementalPatches = recorder.takePatches()
    let snapshotAfter = try syncEngine.extractBroadcastSnapshot(from: initialState, mode: .all)
    let diffPatches = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotAfter, onlyPaths: nil, mode: .all)
    
    return (incrementalPatches, diffPatches)
}

/// Same for nested state (NestedParentState).
func runNestedEquivalenceTest(
    initialState: inout NestedParentState,
    mutate: (inout NestedParentState) -> Void
) throws -> (incremental: [StatePatch], diff: [StatePatch]) {
    let recorder = LandPatchRecorder()
    initialState._$parentPath = ""
    initialState._$patchRecorder = recorder
    initialState._$propagatePatchContext()
    
    var syncEngine = SyncEngine()
    let snapshotBefore = try syncEngine.extractBroadcastSnapshot(from: initialState, mode: .all)
    _ = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotBefore, onlyPaths: nil, mode: .all)
    
    mutate(&initialState)
    
    let incrementalPatches = recorder.takePatches()
    let snapshotAfter = try syncEngine.extractBroadcastSnapshot(from: initialState, mode: .all)
    let diffPatches = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotAfter, onlyPaths: nil, mode: .all)
    
    return (incrementalPatches, diffPatches)
}

// MARK: - ReactiveDictionary: single key

@Test("Incremental vs diff: ReactiveDictionary set one key produces identical patches")
func incrementalVsDiff_ReactiveDictionary_SetOneKey() throws {
    var state = EquivalenceTestState()
    let (inc, diff) = try runEquivalenceTest(initialState: &state) { s in
        s.items["x"] = 42
    }
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (set one key)")
    #expect(inc.count == 1)
    #expect(normalizedPatches(inc)[0].path == "/items/x")
    if case .set(let v) = normalizedPatches(inc)[0].operation {
        #expect(v == .int(42))
    } else {
        Issue.record("Expected .set operation")
    }
}

// MARK: - ReactiveDictionary: multiple keys

@Test("Incremental vs diff: ReactiveDictionary set multiple keys produces identical patches")
func incrementalVsDiff_ReactiveDictionary_MultipleKeys() throws {
    var state = EquivalenceTestState()
    let (inc, diff) = try runEquivalenceTest(initialState: &state) { s in
        s.items["a"] = 1
        s.items["b"] = 2
        s.items["c"] = 3
    }
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (multiple keys)")
    #expect(inc.count == 3)
    let paths = Set(normalizedPatches(inc).map(\.path))
    #expect(paths == ["/items/a", "/items/b", "/items/c"])
}

@Test("Incremental vs diff: ReactiveDictionary update existing key produces identical patches")
func incrementalVsDiff_ReactiveDictionary_UpdateExisting() throws {
    var state = EquivalenceTestState()
    state.items["k"] = 10
    state.clearDirty()
    
    let recorder = LandPatchRecorder()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    var syncEngine = SyncEngine()
    let snapshotBefore = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    _ = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotBefore, onlyPaths: nil, mode: .all)
    
    state.items["k"] = 99
    
    let inc = recorder.takePatches()
    let snapshotAfter = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    let diff = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotAfter, onlyPaths: nil, mode: .all)
    
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (update existing key)")
    #expect(inc.count == 1)
    #expect(normalizedPatches(inc)[0].path == "/items/k")
    if case .set(let v) = normalizedPatches(inc)[0].operation {
        #expect(v == .int(99))
    } else {
        Issue.record("Expected .set operation")
    }
}

// MARK: - ReactiveDictionary: delete

@Test("Incremental vs diff: ReactiveDictionary remove key produces identical patches")
func incrementalVsDiff_ReactiveDictionary_Delete() throws {
    var state = EquivalenceTestState()
    state.items["toRemove"] = 100
    state.clearDirty()
    
    let recorder = LandPatchRecorder()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    var syncEngine = SyncEngine()
    let snapshotBefore = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    _ = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotBefore, onlyPaths: nil, mode: .all)
    
    state.items["toRemove"] = nil
    
    let inc = recorder.takePatches()
    let snapshotAfter = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    let diff = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotAfter, onlyPaths: nil, mode: .all)
    
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (delete key)")
    #expect(inc.count == 1)
    #expect(normalizedPatches(inc)[0].path == "/items/toRemove")
    if case .delete = normalizedPatches(inc)[0].operation {
        // expected
    } else {
        Issue.record("Expected .delete operation, got \(normalizedPatches(inc)[0].operation)")
    }
}

// MARK: - ReactiveDictionary: mixed set and delete

@Test("Incremental vs diff: ReactiveDictionary set one and delete another produces identical patches")
func incrementalVsDiff_ReactiveDictionary_SetAndDelete() throws {
    var state = EquivalenceTestState()
    state.items["keep"] = 1
    state.items["remove"] = 2
    state.clearDirty()
    
    let recorder = LandPatchRecorder()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    var syncEngine = SyncEngine()
    let snapshotBefore = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    _ = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotBefore, onlyPaths: nil, mode: .all)
    
    state.items["new"] = 10
    state.items["remove"] = nil
    
    let inc = recorder.takePatches()
    let snapshotAfter = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    let diff = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotAfter, onlyPaths: nil, mode: .all)
    
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (mixed set and delete)")
    #expect(inc.count == 2)
    let paths = Set(normalizedPatches(inc).map(\.path))
    #expect(paths.contains("/items/new"))
    #expect(paths.contains("/items/remove"))
}

// MARK: - Nested object (ReactiveDictionary + scalar child fields)

@Test("Incremental vs diff: nested state ReactiveDictionary (units) produces identical patches")
func incrementalVsDiff_NestedState_ReactiveDictionaryOnly() throws {
    var state = NestedParentState()
    
    let (inc, diff) = try runNestedEquivalenceTest(initialState: &state) { s in
        s.units["a"] = 1
        s.units["b"] = 2
    }
    #expect(inc.count == 2, "units/a and units/b")
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (nested state dict)")
    let paths = Set(normalizedPatches(inc).map(\.path))
    #expect(paths == ["/units/a", "/units/b"])
}

@Test("Incremental vs diff: nested StateNode scalar fields (child.health, child.name) produce identical patches")
func incrementalVsDiff_NestedStateNode_ScalarFields() throws {
    var state = NestedParentState()
    
    let (inc, diff) = try runNestedEquivalenceTest(initialState: &state) { s in
        s.child.health = 50
        s.child.name = "hero"
    }
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (nested scalar fields)")
    let incNorm = dropRedundantWholeObjectPatches(inc)
    #expect(incNorm.count == 2, "after normalizing: child/health and child/name")
    let paths = Set(normalizedPatches(incNorm).map(\.path))
    #expect(paths.contains("/child/health"))
    #expect(paths.contains("/child/name"))
}

@Test("Incremental vs diff: nested state dict + scalar produces identical patches")
func incrementalVsDiff_NestedState_DictAndScalar() throws {
    var state = NestedParentState()
    
    let (inc, diff) = try runNestedEquivalenceTest(initialState: &state) { s in
        s.units["a"] = 1
        s.child.health = 80
    }
    #expect(patchesEqual(inc, diff), "Incremental and diff patches must be identical (nested dict + scalar)")
    #expect(dropRedundantWholeObjectPatches(inc).count == 2)
}

// MARK: - No change

@Test("Incremental vs diff: no mutation produces no patches from both")
func incrementalVsDiff_NoMutation_NoPatches() throws {
    var state = EquivalenceTestState()
    state.items["x"] = 1
    state.clearDirty()
    
    let recorder = LandPatchRecorder()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    var syncEngine = SyncEngine()
    let snapshotBefore = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    _ = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotBefore, onlyPaths: nil, mode: .all)
    
    // No mutation
    let inc = recorder.takePatches()
    let snapshotAfter = try syncEngine.extractBroadcastSnapshot(from: state, mode: .all)
    let diff = syncEngine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshotAfter, onlyPaths: nil, mode: .all)
    
    #expect(inc.isEmpty)
    #expect(diff.isEmpty)
}
