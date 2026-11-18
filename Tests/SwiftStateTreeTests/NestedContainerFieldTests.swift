// Tests/SwiftStateTreeTests/NestedContainerFieldTests.swift
//
// Compiled fixture for #582. Each @StateNodeBuilder field here has an element type that is
// itself a literal container, or that has its own `:` or `,`. The fixture checks four things:
// - the generated helpers compile with the element and key types as written;
// - each helper marks its field dirty, and `clearDirty()` clears it;
// - `snapshotForSync`'s broadcast part equals `broadcastSnapshot()` (its container branch);
// - a broadcast snapshot decodes back to the same values.
// Together these reach every caller of the macro's container classification: the helpers,
// `snapshotForSync` and `clearDirty`. For a container both of `snapshotForSync`'s branches
// give the same values at run time, and so do both `clearDirty` choices. Which branch was
// generated is pinned by the expansion golden in `StateNodeBuilderContainerTypeTests`.

import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct NestedContainerFieldState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var maps: [[String: Int]] = []
    @Sync(.broadcast) var genericMaps: Array<[String: Int]> = []
    @Sync(.broadcast) var grid: [String: [Int: Int]] = [:]
    @Sync(.broadcast) var buckets: [String: [[String: Int]]] = [:]
    @Sync(.broadcast) var nested: Dictionary<String, Dictionary<String, Int>> = [:]
    @Sync(.serverOnly) var pairs: [(a: Int, b: Int)] = []
    @Sync(.serverOnly) var labeled: [Int: (a: Int, b: Int)] = [:]

    init() {}
}

@Suite("Nested container fields (#582)")
struct NestedContainerFieldTests {
    /// Runs `mutate` on a clean state and expects exactly `field` dirty afterwards.
    private func expectMarksOnly(
        _ field: String,
        _ state: inout NestedContainerFieldState,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutate: (inout NestedContainerFieldState) -> Void
    ) {
        state.clearDirty()
        #expect(state.getDirtyFields().isEmpty, sourceLocation: sourceLocation)
        mutate(&state)
        #expect(state.getDirtyFields() == [field], sourceLocation: sourceLocation)
    }

    @Test("Array helpers take the inner dictionary as the element type, and each marks its field")
    func arrayOfDictionariesHelpers() {
        var state = NestedContainerFieldState()
        expectMarksOnly("maps", &state) { $0.appendMaps(["a": 1]) }
        expectMarksOnly("maps", &state) { $0.insertMaps(["b": 2], at: 0) }
        #expect(state.maps == [["b": 2], ["a": 1]])
        expectMarksOnly("maps", &state) { #expect($0.removeMaps(at: 0) == ["b": 2]) }
        expectMarksOnly("genericMaps", &state) { $0.appendGenericMaps(["c": 3]) }
        #expect(state.maps == [["a": 1]])
        #expect(state.genericMaps == [["c": 3]])
    }

    @Test("Dictionary helpers take the inner container as the value type, and each marks its field")
    func dictionaryOfContainersHelpers() {
        var state = NestedContainerFieldState()
        expectMarksOnly("grid", &state) { $0.updateGrid([1: 10], forKey: "row") }
        expectMarksOnly("grid", &state) { $0.setGrid([2: 20], forKey: "col") }
        expectMarksOnly("grid", &state) { #expect($0.removeGrid(forKey: "col") == [2: 20]) }
        expectMarksOnly("buckets", &state) { $0.setBuckets([["x": 1]], forKey: "k") }
        expectMarksOnly("nested", &state) { $0.updateNested(["y": 2], forKey: "n") }
        #expect(state.grid == ["row": [1: 10]])
        #expect(state.buckets == ["k": [["x": 1]]])
        #expect(state.nested == ["n": ["y": 2]])
    }

    @Test("Labeled tuple elements and values keep their labels, and each helper marks its field")
    func labeledTupleHelpers() {
        var state = NestedContainerFieldState()
        expectMarksOnly("pairs", &state) { $0.appendPairs((a: 1, b: 2)) }
        expectMarksOnly("labeled", &state) { $0.updateLabeled((a: 3, b: 4), forKey: 7) }
        #expect(state.pairs.count == 1 && state.pairs[0].a == 1 && state.pairs[0].b == 2)
        #expect(state.labeled[7]?.b == 4)
    }

    @Test("snapshotForSync's broadcast part equals broadcastSnapshot, and clearDirty clears every field")
    func snapshotForSyncAndClearDirty() throws {
        var state = NestedContainerFieldState()
        state.appendMaps(["a": 1])
        state.appendGenericMaps(["c": 3])
        state.updateGrid([1: 10], forKey: "row")
        state.updateBuckets([["x": 1], [:]], forKey: "k")
        state.updateNested(["y": 2], forKey: "n")
        state.appendPairs((a: 1, b: 2))
        state.updateLabeled((a: 3, b: 4), forKey: 7)

        let sync = try state.snapshotForSync(playerIDs: [], dirtyFields: nil)
        let broadcast = try state.broadcastSnapshot()
        #expect(sync.broadcast.values == broadcast.values)
        #expect(Set(broadcast.values.keys) == ["maps", "genericMaps", "grid", "buckets", "nested"])

        #expect(state.getDirtyFields() == ["maps", "genericMaps", "grid", "buckets", "nested", "pairs", "labeled"])
        state.clearDirty()
        #expect(state.getDirtyFields().isEmpty)
        #expect(!state.isDirty())
    }

    @Test("Broadcast snapshot of nested containers decodes back to the same values")
    func broadcastSnapshotRoundTrip() throws {
        var state = NestedContainerFieldState()
        state.appendMaps(["a": 1, "b": 2])
        state.appendGenericMaps(["c": 3])
        state.updateGrid([1: 10, 2: 20], forKey: "row")
        state.updateBuckets([["x": 1], [:]], forKey: "k")
        state.updateNested(["y": 2], forKey: "n")

        let decoded = try NestedContainerFieldState(fromBroadcastSnapshot: try state.broadcastSnapshot())
        #expect(decoded.maps == state.maps)
        #expect(decoded.genericMaps == state.genericMaps)
        #expect(decoded.grid == state.grid)
        #expect(decoded.buckets == state.buckets)
        #expect(decoded.nested == state.nested)
    }
}
