// Tests/SwiftStateTreeTests/ReactiveDictionaryTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Initialization Tests

@Test("ReactiveDictionary initializes with empty dictionary")
func testReactiveDictionary_Initialization_Empty() {
    // Arrange & Act
    let dict = ReactiveDictionary<String, Int>()
    
    // Assert
    #expect(dict.isEmpty == true, "Dictionary should be empty")
    #expect(dict.count == 0, "Dictionary count should be 0")
    #expect(dict.isDirty == false, "New dictionary should not be dirty")
    #expect(dict.dirtyKeys.isEmpty == true, "Dirty keys should be empty")
}

@Test("ReactiveDictionary initializes with initial values")
func testReactiveDictionary_Initialization_WithValues() {
    // Arrange & Act
    let dict = ReactiveDictionary<String, Int>(["a": 1, "b": 2])
    
    // Assert
    #expect(dict.count == 2, "Dictionary should have 2 elements")
    #expect(dict["a"] == 1, "Value for 'a' should be 1")
    #expect(dict["b"] == 2, "Value for 'b' should be 2")
    #expect(dict.isDirty == false, "New dictionary should not be dirty")
}

// MARK: - Subscript Tests

@Test("ReactiveDictionary subscript get returns correct value")
func testReactiveDictionary_Subscript_Get() {
    // Arrange
    let dict = ReactiveDictionary<String, Int>(["key": 42])
    
    // Act & Assert
    #expect(dict["key"] == 42, "Should return correct value")
    #expect(dict["nonexistent"] == nil, "Should return nil for nonexistent key")
}

@Test("ReactiveDictionary subscript set marks dictionary as dirty")
func testReactiveDictionary_Subscript_Set_MarksDirty() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    
    // Act
    dict["key"] = 42
    
    // Assert
    #expect(dict.isDirty == true, "Dictionary should be marked as dirty")
    #expect(dict.dirtyKeys.contains("key") == true, "Key should be in dirtyKeys")
    #expect(dict["key"] == 42, "Value should be set correctly")
}

@Test("ReactiveDictionary subscript set triggers onChange callback")
func testReactiveDictionary_Subscript_Set_TriggersOnChange() async {
    // Arrange
    actor CallbackTracker {
        var invoked = false
        func markInvoked() { invoked = true }
    }
    let tracker = CallbackTracker()
    var dict = ReactiveDictionary<String, Int>(onChange: {
        Task { await tracker.markInvoked() }
    })
    
    // Act
    dict["key"] = 42
    
    // Wait a bit for async callback
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    // Assert
    let invoked = await tracker.invoked
    #expect(invoked == true, "onChange callback should be invoked")
}

@Test("ReactiveDictionary subscript set with nil removes key")
func testReactiveDictionary_Subscript_Set_Nil() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>(["key": 42])
    
    // Act
    dict["key"] = nil
    
    // Assert
    #expect(dict["key"] == nil, "Key should be removed")
    #expect(dict.isDirty == true, "Dictionary should be marked as dirty")
    #expect(dict.dirtyKeys.contains("key") == true, "Key should be in dirtyKeys")
}

// MARK: - removeValue Tests

@Test("ReactiveDictionary removeValue removes existing key")
func testReactiveDictionary_RemoveValue_ExistingKey() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>(["key": 42])
    
    // Act
    let removed = dict.removeValue(forKey: "key")
    
    // Assert
    #expect(removed == 42, "Should return removed value")
    #expect(dict["key"] == nil, "Key should be removed")
    #expect(dict.isDirty == true, "Dictionary should be marked as dirty")
    #expect(dict.dirtyKeys.contains("key") == true, "Key should be in dirtyKeys")
}

@Test("ReactiveDictionary removeValue returns nil for nonexistent key")
func testReactiveDictionary_RemoveValue_NonexistentKey() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    
    // Act
    let removed = dict.removeValue(forKey: "nonexistent")
    
    // Assert
    #expect(removed == nil, "Should return nil")
    #expect(dict.isDirty == false, "Dictionary should not be marked as dirty")
    #expect(dict.dirtyKeys.contains("nonexistent") == false, "Key should not be in dirtyKeys")
}

@Test("ReactiveDictionary removeValue triggers onChange callback")
func testReactiveDictionary_RemoveValue_TriggersOnChange() async {
    // Arrange
    actor CallbackTracker {
        var invoked = false
        func markInvoked() { invoked = true }
    }
    let tracker = CallbackTracker()
    var dict = ReactiveDictionary<String, Int>(["key": 42], onChange: {
        Task { await tracker.markInvoked() }
    })
    
    // Act
    _ = dict.removeValue(forKey: "key")
    
    // Wait a bit for async callback
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    // Assert
    let invoked = await tracker.invoked
    #expect(invoked == true, "onChange callback should be invoked")
}

// MARK: - updateValue Tests

@Test("ReactiveDictionary updateValue updates existing key")
func testReactiveDictionary_UpdateValue_ExistingKey() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>(["key": 42])
    
    // Act
    let oldValue = dict.updateValue(100, forKey: "key")
    
    // Assert
    #expect(oldValue == 42, "Should return old value")
    #expect(dict["key"] == 100, "Value should be updated")
    #expect(dict.isDirty == true, "Dictionary should be marked as dirty")
    #expect(dict.dirtyKeys.contains("key") == true, "Key should be in dirtyKeys")
}

@Test("ReactiveDictionary updateValue inserts new key")
func testReactiveDictionary_UpdateValue_NewKey() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    
    // Act
    let oldValue = dict.updateValue(42, forKey: "key")
    
    // Assert
    #expect(oldValue == nil, "Should return nil for new key")
    #expect(dict["key"] == 42, "Value should be inserted")
    #expect(dict.isDirty == true, "Dictionary should be marked as dirty")
    #expect(dict.dirtyKeys.contains("key") == true, "Key should be in dirtyKeys")
}

@Test("ReactiveDictionary updateValue triggers onChange callback")
func testReactiveDictionary_UpdateValue_TriggersOnChange() async {
    // Arrange
    actor CallbackTracker {
        var invoked = false
        func markInvoked() { invoked = true }
    }
    let tracker = CallbackTracker()
    var dict = ReactiveDictionary<String, Int>(onChange: {
        Task { await tracker.markInvoked() }
    })
    
    // Act
    _ = dict.updateValue(42, forKey: "key")
    
    // Wait a bit for async callback
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    // Assert
    let invoked = await tracker.invoked
    #expect(invoked == true, "onChange callback should be invoked")
}

// MARK: - mutateValue Tests

@Test("ReactiveDictionary mutateValue mutates existing value")
func testReactiveDictionary_MutateValue_ExistingKey() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>(["key": 42])
    
    // Act
    dict.mutateValue(for: "key") { value in
        value += 10
    }
    
    // Assert
    #expect(dict["key"] == 52, "Value should be mutated")
    #expect(dict.isDirty == true, "Dictionary should be marked as dirty")
    #expect(dict.dirtyKeys.contains("key") == true, "Key should be in dirtyKeys")
}

@Test("ReactiveDictionary mutateValue does nothing for nonexistent key")
func testReactiveDictionary_MutateValue_NonexistentKey() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    
    // Act
    dict.mutateValue(for: "nonexistent") { value in
        value += 10
    }
    
    // Assert
    #expect(dict["nonexistent"] == nil, "Key should not exist")
    #expect(dict.isDirty == false, "Dictionary should not be marked as dirty")
}

@Test("ReactiveDictionary mutateValue triggers onChange callback")
func testReactiveDictionary_MutateValue_TriggersOnChange() async {
    // Arrange
    actor CallbackTracker {
        var invoked = false
        func markInvoked() { invoked = true }
    }
    let tracker = CallbackTracker()
    var dict = ReactiveDictionary<String, Int>(["key": 42], onChange: {
        Task { await tracker.markInvoked() }
    })
    
    // Act
    dict.mutateValue(for: "key") { value in
        value += 10
    }
    
    // Wait a bit for async callback
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    // Assert
    let invoked = await tracker.invoked
    #expect(invoked == true, "onChange callback should be invoked")
}

// MARK: - Collection Properties Tests

@Test("ReactiveDictionary keys returns all keys")
func testReactiveDictionary_Keys() {
    // Arrange
    let dict = ReactiveDictionary<String, Int>(["a": 1, "b": 2, "c": 3])
    
    // Act
    let keys = Set(dict.keys)
    
    // Assert
    #expect(keys.count == 3, "Should have 3 keys")
    #expect(keys.contains("a") == true, "Should contain 'a'")
    #expect(keys.contains("b") == true, "Should contain 'b'")
    #expect(keys.contains("c") == true, "Should contain 'c'")
}

@Test("ReactiveDictionary values returns all values")
func testReactiveDictionary_Values() {
    // Arrange
    let dict = ReactiveDictionary<String, Int>(["a": 1, "b": 2, "c": 3])
    
    // Act
    let values = Set(dict.values)
    
    // Assert
    #expect(values.count == 3, "Should have 3 values")
    #expect(values.contains(1) == true, "Should contain 1")
    #expect(values.contains(2) == true, "Should contain 2")
    #expect(values.contains(3) == true, "Should contain 3")
}

@Test("ReactiveDictionary count returns correct count")
func testReactiveDictionary_Count() {
    // Arrange
    let dict = ReactiveDictionary<String, Int>(["a": 1, "b": 2])
    
    // Assert
    #expect(dict.count == 2, "Count should be 2")
}

@Test("ReactiveDictionary isEmpty returns correct value")
func testReactiveDictionary_IsEmpty() {
    // Arrange
    let emptyDict = ReactiveDictionary<String, Int>()
    let nonEmptyDict = ReactiveDictionary<String, Int>(["a": 1])
    
    // Assert
    #expect(emptyDict.isEmpty == true, "Empty dictionary should be empty")
    #expect(nonEmptyDict.isEmpty == false, "Non-empty dictionary should not be empty")
}

// MARK: - Dirty State Tests

@Test("ReactiveDictionary clearDirty clears dirty state")
func testReactiveDictionary_ClearDirty() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    dict["key"] = 42
    
    // Act
    dict.clearDirty()
    
    // Assert
    #expect(dict.isDirty == false, "Dictionary should not be dirty")
    #expect(dict.dirtyKeys.isEmpty == true, "Dirty keys should be empty")
}

@Test("ReactiveDictionary dirtyKeys tracks multiple keys")
func testReactiveDictionary_DirtyKeys_MultipleKeys() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    
    // Act
    dict["a"] = 1
    dict["b"] = 2
    dict["c"] = 3
    
    // Assert
    #expect(dict.dirtyKeys.count == 3, "Should track 3 dirty keys")
    #expect(dict.dirtyKeys.contains("a") == true, "Should contain 'a'")
    #expect(dict.dirtyKeys.contains("b") == true, "Should contain 'b'")
    #expect(dict.dirtyKeys.contains("c") == true, "Should contain 'c'")
}

@Test("ReactiveDictionary dirtyKeys handles same key multiple times")
func testReactiveDictionary_DirtyKeys_SameKeyMultipleTimes() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    
    // Act
    dict["key"] = 1
    dict["key"] = 2
    dict["key"] = 3
    
    // Assert
    #expect(dict.dirtyKeys.count == 1, "Should only track one key")
    #expect(dict.dirtyKeys.contains("key") == true, "Should contain 'key'")
}

// MARK: - toDictionary Tests

@Test("ReactiveDictionary toDictionary returns correct dictionary")
func testReactiveDictionary_ToDictionary() {
    // Arrange
    let dict = ReactiveDictionary<String, Int>(["a": 1, "b": 2, "c": 3])
    
    // Act
    let result = dict.toDictionary()
    
    // Assert
    #expect(result.count == 3, "Should have 3 elements")
    #expect(result["a"] == 1, "Should contain correct value for 'a'")
    #expect(result["b"] == 2, "Should contain correct value for 'b'")
    #expect(result["c"] == 3, "Should contain correct value for 'c'")
}

// MARK: - Patch Recording Tests

/// Test state for patch recording
struct TestPatchableState: PatchableState, Equatable {
    var _$parentPath: String = ""
    var _$patchRecorder: PatchRecorder? = nil
    var value: Int = 0
    
    static func == (lhs: TestPatchableState, rhs: TestPatchableState) -> Bool {
        // Compare only value, not the injected properties
        lhs.value == rhs.value
    }
}

// MARK: - @unchecked Sendable conformance for testing
// Required because PatchRecorder is not Sendable, but this struct is only used in tests
extension TestPatchableState: @unchecked Sendable {}

@Test("ReactiveDictionary subscript get injects path context into PatchableState")
func testReactiveDictionary_SubscriptGet_InjectsPathContext() {
    // Arrange
    var dict = ReactiveDictionary<String, TestPatchableState>()
    dict._$parentPath = "/players"
    let recorder = LandPatchRecorder()
    dict._$patchRecorder = recorder
    
    // Set up initial value
    dict["A"] = TestPatchableState(value: 100)
    dict.clearDirty()
    
    // Act
    let retrieved = dict["A"]
    
    // Assert
    #expect(retrieved != nil)
    #expect(retrieved?._$parentPath == "/players/A")
    #expect(retrieved?._$patchRecorder === recorder)
}

@Test("ReactiveDictionary subscript set records patch")
func testReactiveDictionary_SubscriptSet_RecordsPatch() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    dict._$parentPath = "/scores"
    let recorder = LandPatchRecorder()
    dict._$patchRecorder = recorder
    
    // Act
    dict["player1"] = 100
    
    // Assert
    #expect(recorder.hasPatches == true)
    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path == "/scores/player1")
}

@Test("ReactiveDictionary subscript set nil records delete patch")
func testReactiveDictionary_SubscriptSetNil_RecordsDeletePatch() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    dict._$parentPath = "/scores"
    let recorder = LandPatchRecorder()
    dict._$patchRecorder = recorder
    
    // Set initial value
    dict["player1"] = 100
    _ = recorder.takePatches() // Clear initial patch
    
    // Act
    dict["player1"] = nil
    
    // Assert
    #expect(recorder.hasPatches == true)
    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path == "/scores/player1")
    if case .delete = patches[0].operation {
        // Expected
    } else {
        Issue.record("Expected delete operation")
    }
}

// MARK: - Integration Tests

@Test("ReactiveDictionary maintains state across multiple operations")
func testReactiveDictionary_Integration_MultipleOperations() async {
    // Arrange
    actor CallbackTracker {
        var count = 0
        func increment() { count += 1 }
    }
    let tracker = CallbackTracker()
    var dict = ReactiveDictionary<String, Int>(onChange: {
        Task { await tracker.increment() }
    })
    
    // Act
    dict["a"] = 1
    dict["b"] = 2
    _ = dict.removeValue(forKey: "a")
    _ = dict.updateValue(3, forKey: "b")
    dict["c"] = 4
    
    // Wait a bit for async callbacks
    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    
    // Assert
    #expect(dict.count == 2, "Should have 2 elements")
    #expect(dict["b"] == 3, "Value for 'b' should be 3")
    #expect(dict["c"] == 4, "Value for 'c' should be 4")
    #expect(dict.isDirty == true, "Dictionary should be dirty")
    #expect(dict.dirtyKeys.count == 3, "Should track 3 dirty keys (a, b, c)")
    let callbackCount = await tracker.count
    #expect(callbackCount == 5, "onChange should be called 5 times")
    
    // Clear dirty and verify
    dict.clearDirty()
    #expect(dict.isDirty == false, "Dictionary should not be dirty after clear")
    #expect(dict.dirtyKeys.isEmpty == true, "Dirty keys should be empty")
}

