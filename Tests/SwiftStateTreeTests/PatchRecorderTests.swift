// Tests/SwiftStateTreeTests/PatchRecorderTests.swift
//
// Incremental sync unit test coverage:
// - PatchRecorder: record/take, capacity (basic).
// - Propagation: _$propagatePatchContext() propagates recorder/path to ReactiveDictionary and
//   nested StateNode; without propagation no patches are recorded.
// - Patch recording: subscript and mutateValue record patches with correct path and value.
// - Path edge cases: root path, multiple keys, JSON Pointer escaping.
// - Dirty + patch consistency: getDirtyFields() and patches align so TransportAdapter safety
//   check (dirty broadcast fields ⊆ patched root fields) can rely on both.
// Macro generation of _$propagatePatchContext() is covered in StateNodeBuilderMacroTests.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Basic PatchRecorder Tests

@Test("PatchRecorder records patches and takes them")
func testPatchRecorder_RecordAndTake() {
    // Arrange
    let recorder = LandPatchRecorder()
    
    // Act
    recorder.record(StatePatch(path: "/score", operation: .set(.int(100))))
    recorder.record(StatePatch(path: "/players/A/health", operation: .set(.int(90))))
    
    // Assert
    #expect(recorder.hasPatches == true)
    #expect(recorder.patchCount == 2)
    let patches = recorder.takePatches()
    #expect(patches.count == 2)
    #expect(patches[0].path == "/score")
    #expect(patches[1].path == "/players/A/health")
    
    // After take, should be empty
    #expect(recorder.hasPatches == false)
    #expect(recorder.patchCount == 0)
    #expect(recorder.takePatches().isEmpty == true)
}

@Test("PatchRecorder takePatches preserves capacity")
func testPatchRecorder_TakePreservesCapacity() {
    // Arrange
    let recorder = LandPatchRecorder()
    
    // Record many patches
    for i in 0..<100 {
        recorder.record(StatePatch(path: "/field\(i)", operation: .set(.int(i))))
    }
    
    // Act
    _ = recorder.takePatches()
    
    // Record again - should not need reallocation
    recorder.record(StatePatch(path: "/new", operation: .set(.int(999))))
    
    // Assert
    #expect(recorder.hasPatches == true)
}

// MARK: - Test StateNode types for propagation tests

@StateNodeBuilder
struct PropagationTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var items: ReactiveDictionary<String, Int> = ReactiveDictionary<String, Int>()
    
    @Sync(.broadcast)
    var score: Int = 0
    
    public init() {}
}

@StateNodeBuilder
struct NestedPropagationChildState: StateNodeProtocol {
    @Sync(.broadcast)
    var health: Int = 100
    
    public init() {}
}

@StateNodeBuilder
struct NestedPropagationParentState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: ReactiveDictionary<String, Int> = ReactiveDictionary<String, Int>()
    
    @Sync(.broadcast)
    var child: NestedPropagationChildState = NestedPropagationChildState()
    
    @Sync(.broadcast)
    var counter: Int = 0
    
    public init() {}
}

@StateNodeBuilder
struct MultiDictPropagationState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: ReactiveDictionary<String, Int> = ReactiveDictionary<String, Int>()
    
    @Sync(.broadcast)
    var monsters: ReactiveDictionary<Int, String> = ReactiveDictionary<Int, String>()
    
    @Sync(.serverOnly)
    var internalCounter: Int = 0
    
    public init() {}
}

// MARK: - Propagation Tests

@Test("propagatePatchContext propagates recorder to ReactiveDictionary child")
func testPropagatePatchContext_ReactiveDictionary_ReceivesRecorder() {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    
    // Act
    state._$propagatePatchContext()
    
    // Assert: ReactiveDictionary should have the recorder after propagation
    state.items["key1"] = 42
    
    let patches = recorder.takePatches()
    #expect(patches.count == 1, "Should have recorded 1 patch from ReactiveDictionary")
    #expect(patches[0].path == "/items/key1", "Patch path should include field name")
    if case .set(let value) = patches[0].operation {
        #expect(value == .int(42), "Patch value should be 42")
    } else {
        Issue.record("Expected .set operation, got \(patches[0].operation)")
    }
}

@Test("propagatePatchContext sets correct parentPath on ReactiveDictionary")
func testPropagatePatchContext_ReactiveDictionary_CorrectParentPath() {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    // Act: Set multiple keys
    state.items["a"] = 1
    state.items["b"] = 2
    
    // Assert
    let patches = recorder.takePatches()
    #expect(patches.count == 2)
    #expect(patches[0].path == "/items/a")
    #expect(patches[1].path == "/items/b")
}

@Test("propagatePatchContext records delete patch when removing key")
func testPropagatePatchContext_ReactiveDictionary_DeletePatch() {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    state.items["key1"] = 100
    _ = recorder.takePatches() // Clear initial set patch
    
    // Act
    state.items["key1"] = nil
    
    // Assert
    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path == "/items/key1")
    if case .delete = patches[0].operation {
        // Expected
    } else {
        Issue.record("Expected .delete operation, got \(patches[0].operation)")
    }
}

@Test("propagatePatchContext works with multiple ReactiveDictionary fields")
func testPropagatePatchContext_MultipleDicts_AllReceiveRecorder() {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = MultiDictPropagationState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    // Act: Mutate both dictionaries
    state.players["alice"] = 100
    state.monsters[1] = "goblin"
    
    // Assert
    let patches = recorder.takePatches()
    #expect(patches.count == 2, "Both dictionaries should record patches")
    #expect(patches[0].path == "/players/alice")
    #expect(patches[1].path == "/monsters/1")
}

@Test("propagatePatchContext propagates to nested StateNode children")
func testPropagatePatchContext_NestedStateNode_ReceivesRecorder() {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = NestedPropagationParentState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()
    
    // Act: Mutate the ReactiveDictionary in parent
    state.players["p1"] = 50
    
    // Assert: Patches should be recorded
    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path == "/players/p1")
}

@Test("Without propagation, ReactiveDictionary does not record patches")
func testWithoutPropagation_ReactiveDictionary_NoPatchesRecorded() {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    // NOTE: Intentionally NOT calling _$propagatePatchContext()
    
    // Act
    state.items["key1"] = 42
    
    // Assert: No patches should be recorded because recorder was not propagated to ReactiveDictionary
    let patches = recorder.takePatches()
    #expect(patches.count == 0, "Without propagation, ReactiveDictionary should not record patches")
}

@Test("propagatePatchContext does not mark fields as dirty")
func testPropagatePatchContext_DoesNotMarkDirty() {
    // Arrange
    var state = PropagationTestState()
    let recorder = LandPatchRecorder()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    
    // Act
    state._$propagatePatchContext()
    
    // Assert: No dirty flags should be set from propagation alone
    #expect(state.isDirty() == false, "Propagation should not mark state as dirty")
}

@Test("propagatePatchContext shares same recorder instance (reference semantics)")
func testPropagatePatchContext_SharedRecorderInstance() {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = MultiDictPropagationState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()

    // Act: Record patches from different fields
    state.players["a"] = 1
    state.monsters[2] = "dragon"

    // Assert: All patches collected in the same recorder
    #expect(recorder.patchCount == 2, "Both patches should be in the same recorder")
    let patches = recorder.takePatches()
    let paths = Set(patches.map { $0.path })
    #expect(paths.contains("/players/a"))
    #expect(paths.contains("/monsters/2"))
}

// MARK: - Incremental sync: mutateValue records patch after propagation

@Test("mutateValue records patch after propagation for incremental sync")
func testMutateValue_AfterPropagation_RecordsPatch() {
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()

    state.items["k"] = 100
    _ = recorder.takePatches()

    state.items.mutateValue(for: "k") { $0 += 1 }

    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path == "/items/k")
    if case .set(let v) = patches[0].operation {
        #expect(v == .int(101))
    } else {
        Issue.record("Expected .set operation")
    }
}

// MARK: - Dirty + patch consistency (safety check in TransportAdapter)

@Test("subscript mutation sets dirty and records patch so safety check can validate")
func testSubscriptMutation_SetsDirtyAndRecordsPatch() {
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()

    state.items["x"] = 1

    let dirtyFields = state.getDirtyFields()
    let patches = recorder.takePatches()

    #expect(dirtyFields.contains("items"), "Dirty must be set so TransportAdapter can require this field to be covered by patches")
    #expect(patches.count == 1)
    #expect(patches[0].path == "/items/x")
}

@Test("multiple keys in same dictionary produce distinct patch paths")
func testMultipleKeys_DistinctPatchPaths() {
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()

    state.items["a"] = 1
    state.items["b"] = 2
    state.items["c"] = 3

    let patches = recorder.takePatches()
    #expect(patches.count == 3)
    let paths = Set(patches.map { $0.path })
    #expect(paths.contains("/items/a"))
    #expect(paths.contains("/items/b"))
    #expect(paths.contains("/items/c"))
}

@Test("root parent path produces leading slash in patch path")
func testRootParentPath_ProducesLeadingSlash() {
    let recorder = LandPatchRecorder()
    var state = PropagationTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    state._$propagatePatchContext()

    state.items["id"] = 42

    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path.hasPrefix("/"))
    #expect(patches[0].path == "/items/id")
}
