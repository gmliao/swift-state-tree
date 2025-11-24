// Tests/SwiftStateTreeTests/ReactiveSetTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Initialization Tests

@Test("ReactiveSet initializes with empty set")
func testReactiveSet_Initialization_Empty() {
    // Arrange & Act
    let set = ReactiveSet<String>()
    
    // Assert
    #expect(set.isEmpty == true, "Set should be empty")
    #expect(set.count == 0, "Set count should be 0")
    #expect(set.isDirty == false, "New set should not be dirty")
    #expect(set.insertedElements.isEmpty == true, "Inserted elements should be empty")
    #expect(set.removedElements.isEmpty == true, "Removed elements should be empty")
}

@Test("ReactiveSet initializes with initial values")
func testReactiveSet_Initialization_WithValues() {
    // Arrange & Act
    let set = ReactiveSet<String>(["a", "b", "c"])
    
    // Assert
    #expect(set.count == 3, "Set should have 3 elements")
    #expect(set.contains("a") == true, "Should contain 'a'")
    #expect(set.contains("b") == true, "Should contain 'b'")
    #expect(set.contains("c") == true, "Should contain 'c'")
    #expect(set.isDirty == false, "New set should not be dirty")
}

// MARK: - Basic Access Tests

@Test("ReactiveSet rawValue returns underlying set")
func testReactiveSet_RawValue() {
    // Arrange
    let set = ReactiveSet<String>(["a", "b"])
    
    // Act
    let raw = set.rawValue
    
    // Assert
    #expect(raw.count == 2, "Raw value should have 2 elements")
    #expect(raw.contains("a") == true, "Should contain 'a'")
    #expect(raw.contains("b") == true, "Should contain 'b'")
}

@Test("ReactiveSet contains returns correct value")
func testReactiveSet_Contains() {
    // Arrange
    let set = ReactiveSet<String>(["a", "b"])
    
    // Assert
    #expect(set.contains("a") == true, "Should contain 'a'")
    #expect(set.contains("b") == true, "Should contain 'b'")
    #expect(set.contains("c") == false, "Should not contain 'c'")
}

@Test("ReactiveSet allElements returns all elements")
func testReactiveSet_AllElements() {
    // Arrange
    let set = ReactiveSet<String>(["a", "b", "c"])
    
    // Act
    let elements = set.allElements
    
    // Assert
    #expect(elements.count == 3, "Should have 3 elements")
    #expect(elements.contains("a") == true, "Should contain 'a'")
    #expect(elements.contains("b") == true, "Should contain 'b'")
    #expect(elements.contains("c") == true, "Should contain 'c'")
}

// MARK: - insert Tests

@Test("ReactiveSet insert adds new element")
func testReactiveSet_Insert_NewElement() {
    // Arrange
    var set = ReactiveSet<String>()
    
    // Act
    let result = set.insert("a")
    
    // Assert
    #expect(result.inserted == true, "Element should be inserted")
    #expect(result.memberAfterInsert == "a", "Member should be 'a'")
    #expect(set.contains("a") == true, "Set should contain 'a'")
    #expect(set.isDirty == true, "Set should be marked as dirty")
    #expect(set.insertedElements.contains("a") == true, "Should track 'a' as inserted")
    #expect(set.removedElements.contains("a") == false, "Should not track 'a' as removed")
}

@Test("ReactiveSet insert does not add duplicate element")
func testReactiveSet_Insert_DuplicateElement() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    
    // Act
    let result = set.insert("a")
    
    // Assert
    #expect(result.inserted == false, "Element should not be inserted")
    #expect(set.count == 1, "Set should still have 1 element")
    #expect(set.isDirty == false, "Set should not be marked as dirty")
    #expect(set.insertedElements.contains("a") == false, "Should not track duplicate as inserted")
}

@Test("ReactiveSet insert triggers onChange callback")
func testReactiveSet_Insert_TriggersOnChange() async {
    // Arrange
    actor CallbackTracker {
        var invoked = false
        func markInvoked() { invoked = true }
    }
    let tracker = CallbackTracker()
    var set = ReactiveSet<String>(onChange: {
        Task { await tracker.markInvoked() }
    })
    
    // Act
    _ = set.insert("a")
    
    // Wait a bit for async callback
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    // Assert
    let invoked = await tracker.invoked
    #expect(invoked == true, "onChange callback should be invoked")
}

@Test("ReactiveSet insert removes element from removed set if previously removed")
func testReactiveSet_Insert_RemovesFromRemovedSet() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    _ = set.remove("a")  // Remove it first
    
    // Act
    _ = set.insert("a")  // Insert it back
    
    // Assert
    #expect(set.contains("a") == true, "Set should contain 'a'")
    #expect(set.insertedElements.contains("a") == true, "Should track 'a' as inserted")
    #expect(set.removedElements.contains("a") == false, "Should not track 'a' as removed")
}

// MARK: - remove Tests

@Test("ReactiveSet remove removes existing element")
func testReactiveSet_Remove_ExistingElement() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    
    // Act
    let removed = set.remove("a")
    
    // Assert
    #expect(removed == "a", "Should return removed element")
    #expect(set.contains("a") == false, "Set should not contain 'a'")
    #expect(set.isDirty == true, "Set should be marked as dirty")
    #expect(set.removedElements.contains("a") == true, "Should track 'a' as removed")
    #expect(set.insertedElements.contains("a") == false, "Should not track 'a' as inserted")
}

@Test("ReactiveSet remove returns nil for nonexistent element")
func testReactiveSet_Remove_NonexistentElement() {
    // Arrange
    var set = ReactiveSet<String>()
    
    // Act
    let removed = set.remove("a")
    
    // Assert
    #expect(removed == nil, "Should return nil")
    #expect(set.isDirty == false, "Set should not be marked as dirty")
    #expect(set.removedElements.contains("a") == false, "Should not track nonexistent as removed")
}

@Test("ReactiveSet remove triggers onChange callback")
func testReactiveSet_Remove_TriggersOnChange() async {
    // Arrange
    actor CallbackTracker {
        var invoked = false
        func markInvoked() { invoked = true }
    }
    let tracker = CallbackTracker()
    var set = ReactiveSet<String>(["a"], onChange: {
        Task { await tracker.markInvoked() }
    })
    
    // Act
    _ = set.remove("a")
    
    // Wait a bit for async callback
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    // Assert
    let invoked = await tracker.invoked
    #expect(invoked == true, "onChange callback should be invoked")
}

@Test("ReactiveSet remove removes element from inserted set if previously inserted")
func testReactiveSet_Remove_RemovesFromInsertedSet() {
    // Arrange
    var set = ReactiveSet<String>()
    _ = set.insert("a")  // Insert it first
    
    // Act
    _ = set.remove("a")  // Remove it
    
    // Assert
    #expect(set.contains("a") == false, "Set should not contain 'a'")
    #expect(set.insertedElements.contains("a") == false, "Should not track 'a' as inserted")
    #expect(set.removedElements.contains("a") == true, "Should track 'a' as removed")
}

// MARK: - update Tests

@Test("ReactiveSet update inserts new element")
func testReactiveSet_Update_NewElement() {
    // Arrange
    var set = ReactiveSet<String>()
    
    // Act
    let old = set.update(with: "a")
    
    // Assert
    #expect(old == nil, "Should return nil for new element")
    #expect(set.contains("a") == true, "Set should contain 'a'")
    #expect(set.isDirty == true, "Set should be marked as dirty")
    #expect(set.insertedElements.contains("a") == true, "Should track 'a' as inserted")
}

@Test("ReactiveSet update replaces existing element")
func testReactiveSet_Update_ExistingElement() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    
    // Act
    let old = set.update(with: "a")
    
    // Assert
    #expect(old == "a", "Should return old element")
    #expect(set.contains("a") == true, "Set should still contain 'a'")
    #expect(set.isDirty == true, "Set should be marked as dirty")
    #expect(set.insertedElements.contains("a") == true, "Should track 'a' as inserted")
}

@Test("ReactiveSet update triggers onChange callback")
func testReactiveSet_Update_TriggersOnChange() async {
    // Arrange
    actor CallbackTracker {
        var invoked = false
        func markInvoked() { invoked = true }
    }
    let tracker = CallbackTracker()
    var set = ReactiveSet<String>(onChange: {
        Task { await tracker.markInvoked() }
    })
    
    // Act
    _ = set.update(with: "a")
    
    // Wait a bit for async callback
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    // Assert
    let invoked = await tracker.invoked
    #expect(invoked == true, "onChange callback should be invoked")
}

// MARK: - formUnion Tests

@Test("ReactiveSet formUnion adds all elements from other set")
func testReactiveSet_FormUnion() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    
    // Act
    set.formUnion(["b", "c"])
    
    // Assert
    #expect(set.count == 3, "Set should have 3 elements")
    #expect(set.contains("a") == true, "Should contain 'a'")
    #expect(set.contains("b") == true, "Should contain 'b'")
    #expect(set.contains("c") == true, "Should contain 'c'")
    #expect(set.isDirty == true, "Set should be marked as dirty")
    #expect(set.insertedElements.contains("b") == true, "Should track 'b' as inserted")
    #expect(set.insertedElements.contains("c") == true, "Should track 'c' as inserted")
}

@Test("ReactiveSet formUnion does nothing with empty set")
func testReactiveSet_FormUnion_EmptySet() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    set.clearDirty()
    
    // Act
    set.formUnion([])
    
    // Assert
    #expect(set.count == 1, "Set should still have 1 element")
    #expect(set.isDirty == false, "Set should not be marked as dirty")
}

@Test("ReactiveSet formUnion handles duplicates correctly")
func testReactiveSet_FormUnion_Duplicates() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    
    // Act
    set.formUnion(["a", "b"])
    
    // Assert
    #expect(set.count == 2, "Set should have 2 elements")
    #expect(set.contains("a") == true, "Should contain 'a'")
    #expect(set.contains("b") == true, "Should contain 'b'")
    // 'a' was already present, so it shouldn't be in insertedElements
    #expect(set.insertedElements.contains("b") == true, "Should track 'b' as inserted")
}

// MARK: - subtract Tests

@Test("ReactiveSet subtract removes elements from other set")
func testReactiveSet_Subtract() {
    // Arrange
    var set = ReactiveSet<String>(["a", "b", "c"])
    
    // Act
    set.subtract(["b", "c"])
    
    // Assert
    #expect(set.count == 1, "Set should have 1 element")
    #expect(set.contains("a") == true, "Should contain 'a'")
    #expect(set.contains("b") == false, "Should not contain 'b'")
    #expect(set.contains("c") == false, "Should not contain 'c'")
    #expect(set.isDirty == true, "Set should be marked as dirty")
    #expect(set.removedElements.contains("b") == true, "Should track 'b' as removed")
    #expect(set.removedElements.contains("c") == true, "Should track 'c' as removed")
}

@Test("ReactiveSet subtract does nothing with empty set")
func testReactiveSet_Subtract_EmptySet() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    set.clearDirty()
    
    // Act
    set.subtract([])
    
    // Assert
    #expect(set.count == 1, "Set should still have 1 element")
    #expect(set.isDirty == false, "Set should not be marked as dirty")
}

@Test("ReactiveSet subtract handles nonexistent elements correctly")
func testReactiveSet_Subtract_NonexistentElements() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    
    // Act
    set.subtract(["b", "c"])
    
    // Assert
    #expect(set.count == 1, "Set should still have 1 element")
    #expect(set.contains("a") == true, "Should contain 'a'")
    // Nonexistent elements shouldn't be tracked as removed
    #expect(set.removedElements.contains("b") == false, "Should not track 'b' as removed")
    #expect(set.removedElements.contains("c") == false, "Should not track 'c' as removed")
}

// MARK: - Dirty State Tests

@Test("ReactiveSet clearDirty clears dirty state")
func testReactiveSet_ClearDirty() {
    // Arrange
    var set = ReactiveSet<String>()
    _ = set.insert("a")
    
    // Act
    set.clearDirty()
    
    // Assert
    #expect(set.isDirty == false, "Set should not be dirty")
    #expect(set.insertedElements.isEmpty == true, "Inserted elements should be empty")
    #expect(set.removedElements.isEmpty == true, "Removed elements should be empty")
}

@Test("ReactiveSet dirtyElements returns union of inserted and removed")
func testReactiveSet_DirtyElements() {
    // Arrange
    var set = ReactiveSet<String>(["a"])
    
    // Act
    _ = set.insert("b")
    _ = set.remove("a")
    
    // Assert
    let dirty = set.dirtyElements
    #expect(dirty.count == 2, "Should have 2 dirty elements")
    #expect(dirty.contains("a") == true, "Should contain 'a'")
    #expect(dirty.contains("b") == true, "Should contain 'b'")
}

@Test("ReactiveSet dirtyElements handles overlapping inserted and removed")
func testReactiveSet_DirtyElements_Overlapping() {
    // Arrange
    var set = ReactiveSet<String>()
    
    // Act
    _ = set.insert("a")
    _ = set.remove("a")
    _ = set.insert("a")  // Insert again
    
    // Assert
    let dirty = set.dirtyElements
    #expect(dirty.contains("a") == true, "Should contain 'a' in dirty elements")
    // After insert again, 'a' should be in inserted, not removed
    #expect(set.insertedElements.contains("a") == true, "Should track 'a' as inserted")
    #expect(set.removedElements.contains("a") == false, "Should not track 'a' as removed")
}

// MARK: - Integration Tests

@Test("ReactiveSet maintains state across multiple operations")
func testReactiveSet_Integration_MultipleOperations() async {
    // Arrange
    actor CallbackTracker {
        var count = 0
        func increment() { count += 1 }
    }
    let tracker = CallbackTracker()
    var set = ReactiveSet<String>(onChange: {
        Task { await tracker.increment() }
    })
    
    // Act
    _ = set.insert("a")
    _ = set.insert("b")
    _ = set.remove("a")
    _ = set.update(with: "c")
    set.formUnion(["d", "e"])
    set.subtract(["b"])
    
    // Wait a bit for async callbacks
    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    
    // Assert
    #expect(set.count == 3, "Should have 3 elements (c, d, e)")
    #expect(set.contains("c") == true, "Should contain 'c'")
    #expect(set.contains("d") == true, "Should contain 'd'")
    #expect(set.contains("e") == true, "Should contain 'e'")
    #expect(set.isDirty == true, "Set should be dirty")
    let callbackCount = await tracker.count
    #expect(callbackCount >= 6, "onChange should be called multiple times")
    
    // Clear dirty and verify
    set.clearDirty()
    #expect(set.isDirty == false, "Set should not be dirty after clear")
    #expect(set.insertedElements.isEmpty == true, "Inserted elements should be empty")
    #expect(set.removedElements.isEmpty == true, "Removed elements should be empty")
}

@Test("ReactiveSet handles rapid insert and remove cycles")
func testReactiveSet_Integration_RapidCycles() {
    // Arrange
    var set = ReactiveSet<String>()
    
    // Act - rapid insert/remove cycles
    _ = set.insert("a")
    _ = set.remove("a")
    _ = set.insert("a")
    _ = set.remove("a")
    _ = set.insert("a")
    
    // Assert
    #expect(set.contains("a") == true, "Should contain 'a' after final insert")
    #expect(set.isDirty == true, "Set should be dirty")
    #expect(set.insertedElements.contains("a") == true, "Should track 'a' as inserted")
    #expect(set.removedElements.contains("a") == false, "Should not track 'a' as removed")
}

