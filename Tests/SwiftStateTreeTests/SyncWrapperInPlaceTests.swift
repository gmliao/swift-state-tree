// Tests/SwiftStateTreeTests/SyncWrapperInPlaceTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

/// An object that only the probe holding it references, while no copy of that probe exists.
final class InPlaceBox: Sendable {}

/// A synced value that can tell whether it was copied: a copy of the probe, or of a collection
/// or node holding it, references the same box.
struct InPlaceProbe: Equatable, Sendable {
    var box = InPlaceBox()
    var count = 0

    /// Whether this probe is the only holder of its box: false after any copy that is still alive.
    mutating func isUnique() -> Bool {
        isKnownUniquelyReferenced(&box)
    }

    static func == (lhs: InPlaceProbe, rhs: InPlaceProbe) -> Bool {
        lhs.box === rhs.box && lhs.count == rhs.count
    }
}

@StateNodeBuilder
struct InPlaceChildState: StateNodeProtocol {
    @Sync(.broadcast)
    var probe: InPlaceProbe = InPlaceProbe()
}

@StateNodeBuilder
struct InPlaceTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var items: [Int: InPlaceProbe] = [:]

    @Sync(.broadcast)
    var list: [InPlaceProbe] = []

    @Sync(.broadcast)
    var child: InPlaceChildState = InPlaceChildState()

    @Sync(.broadcast)
    var total: Int = 0
}

private struct WriteThenThrow: Error {}

/// A mutation through an `inout` parameter (`f(&state.items)`).
private func isElementUnique(_ items: inout [Int: InPlaceProbe], key: Int) -> Bool {
    items[key]!.isUnique()
}

/// Writes, then throws: the write must be kept and the field marked dirty (#87).
private func writeThenThrow(_ items: inout [Int: InPlaceProbe], key: Int) throws {
    items[key] = InPlaceProbe(count: 7)
    throw WriteThenThrow()
}

extension InPlaceTestState {
    /// A write through the wrapper itself (`_items.wrappedValue`), as generated code writes,
    /// in a call that throws. Unlike a write through `items`, this access is ended by the throw
    /// without running the wrapper's code after its `yield`.
    mutating func writeThroughWrapperThenThrow(key: Int) throws {
        try writeThenThrow(&_items.wrappedValue, key: key)
    }
}

/// The address of an array's element storage, to tell whether a write reallocated it.
private func storageAddress(_ list: [InPlaceProbe]) -> UnsafeRawPointer? {
    list.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
}

/// The identity of a dictionary's storage. A `Dictionary` is one reference to its storage
/// (`unsafeBitCast` traps if the sizes differ), so a write that copies the dictionary changes it
/// and a write in place keeps it. Used where a copy is freed by the time the write returns, so a
/// box probe would be unique again.
private func storageIdentity(_ items: [Int: InPlaceProbe]) -> UnsafeRawPointer {
    unsafeBitCast(items, to: UnsafeRawPointer.self)
}

/// A write through a `@Sync` field mutates the stored value in place: a uniquely held collection
/// or node isn't copied, and the field is marked dirty as an assignment marks it.
///
/// `Sync.wrappedValue` with only `get` and `set` is modified by a get into a temporary, the
/// mutation, and a set. While the temporary exists the stored value still holds the collection's
/// buffer, so the mutation copies the whole collection: one write per element made a loop over
/// a dictionary quadratic.
@Suite("Sync wrapper in-place writes")
struct SyncWrapperInPlaceTests {
    private func makeState() -> InPlaceTestState {
        var state = InPlaceTestState()
        state.items = [0: InPlaceProbe(), 1: InPlaceProbe()]
        state.list = [InPlaceProbe(), InPlaceProbe()]
        state.child = InPlaceChildState()
        state.clearDirty()
        return state
    }

    @Test("A dictionary element written through the field isn't copied")
    func dictionaryElement() {
        var state = makeState()
        let unique = state.items[0]!.isUnique()
        #expect(unique)
        #expect(state.getDirtyFields() == ["items"])
    }

    @Test("An array element written through the field isn't copied")
    func arrayElement() {
        var state = makeState()
        let unique = state.list[0].isUnique()
        #expect(unique)
        #expect(state.getDirtyFields() == ["list"])
    }

    @Test("A field passed inout isn't copied")
    func inoutArgument() {
        var state = makeState()
        let unique = isElementUnique(&state.items, key: 1)
        #expect(unique)
        #expect(state.getDirtyFields() == ["items"])
    }

    @Test("A nested node's field written through both wrappers isn't copied")
    func nestedNodeField() {
        var state = makeState()
        let unique = state.child.probe.isUnique()
        #expect(unique)
        #expect(state.getDirtyFields() == ["child"])
        #expect(state.child.getDirtyFields() == ["probe"])
    }

    @Test("Writes in a loop over the field copy it once, at the first write")
    func loopOverTheField() {
        var state = makeState()
        var addresses: [UnsafeRawPointer?] = []
        // The loop holds the array it iterates, so the first write copies; the copy is then
        // the field's own, and the second write must not copy it again.
        for (index, _) in state.list.enumerated() {
            state.list[index].count += 1
            addresses.append(storageAddress(state.list))
        }
        #expect(addresses.count == 2)
        #expect(addresses[0] == addresses[1])
        #expect(state.list.map(\.count) == [1, 1])
        #expect(state.getDirtyFields() == ["list"])
    }

    // The macro's container helpers write through `_x.wrappedValue` and then mark the field.
    // A helper that copied (`var v = _items.wrappedValue; v[key] = value; _items.wrappedValue = v`)
    // frees the old storage before it returns, so these compare the storage, not a box.

    @Test("The dictionary helpers write in place")
    func dictionaryHelpers() {
        var state = makeState()
        let before = storageIdentity(state.items)
        state.updateItems(InPlaceProbe(count: 3), forKey: 0)
        let afterUpdate = storageIdentity(state.items)
        state.removeItems(forKey: 1)
        let afterRemove = storageIdentity(state.items)
        #expect(afterUpdate == before)
        #expect(afterRemove == before)
        #expect(state.items[0]?.count == 3)
        #expect(state.items[1] == nil)
        #expect(state.getDirtyFields() == ["items"])
    }

    @Test("The array helpers write in place")
    func arrayHelpers() {
        var state = makeState()
        state.list.reserveCapacity(8)
        state.clearDirty()
        let before = storageAddress(state.list)
        state.appendList(InPlaceProbe(count: 1))
        let afterAppend = storageAddress(state.list)
        state.insertList(InPlaceProbe(count: 2), at: 0)
        let afterInsert = storageAddress(state.list)
        state.removeList(at: 1)
        let afterRemove = storageAddress(state.list)
        #expect(afterAppend == before)
        #expect(afterInsert == before)
        #expect(afterRemove == before)
        #expect(state.list.map(\.count) == [2, 0, 1])
        #expect(state.getDirtyFields() == ["list"])
    }

    @Test("After a copy of the state, the first write copies the field once and later writes don't")
    func retainedCopy() {
        var state = makeState()
        let before = storageIdentity(state.items)
        // Like the keeper's sync snapshot and its debug copy before a handler.
        let copy = state
        state.items[0]!.count = 5
        let afterFirst = storageIdentity(state.items)
        state.items[1]!.count = 6
        let afterSecond = storageIdentity(state.items)
        #expect(afterFirst != before)
        #expect(afterSecond == afterFirst)
        #expect(storageIdentity(copy.items) == before)
        #expect(copy.items[0]?.count == 0)
        #expect(copy.items[1]?.count == 0)
        #expect(state.items[0]?.count == 5)
        #expect(state.items[1]?.count == 6)
    }

    @Test("A write before a throw is kept and marks the field dirty")
    func throwingInoutWrite() {
        var state = makeState()
        #expect(throws: WriteThenThrow.self) {
            try writeThenThrow(&state.items, key: 2)
        }
        #expect(state.items[2]?.count == 7)
        #expect(state.getDirtyFields() == ["items"])
    }

    @Test("A write through the wrapper before a throw is kept and marks the field dirty")
    func throwingWriteThroughTheWrapper() {
        var state = makeState()
        #expect(throws: WriteThenThrow.self) {
            try state.writeThroughWrapperThenThrow(key: 3)
        }
        #expect(state.items[3]?.count == 7)
        #expect(state.getDirtyFields() == ["items"])
    }

    @Test("A scalar compound assignment marks the field dirty")
    func scalarField() {
        var state = makeState()
        state.total += 1
        #expect(state.total == 1)
        #expect(state.getDirtyFields() == ["total"])
    }
}
