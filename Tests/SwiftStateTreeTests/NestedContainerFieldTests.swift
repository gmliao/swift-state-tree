// Tests/SwiftStateTreeTests/NestedContainerFieldTests.swift
//
// Compiled fixture for #582: @StateNodeBuilder fields whose element type is itself a literal
// container (or has its own `:` / `,`) must expand to helpers that compile with the element
// and key types as written, mark the field dirty, and survive a broadcast snapshot round trip.

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
    @Test("Array helpers take the inner dictionary as the element type")
    func arrayOfDictionariesHelpers() {
        var state = NestedContainerFieldState()
        state.appendMaps(["a": 1])
        state.insertMaps(["b": 2], at: 0)
        state.appendGenericMaps(["c": 3])
        #expect(state.maps == [["b": 2], ["a": 1]])
        #expect(state.removeMaps(at: 0) == ["b": 2])
        #expect(state.genericMaps == [["c": 3]])
        #expect(state.getDirtyFields().isSuperset(of: ["maps", "genericMaps"]))
    }

    @Test("Dictionary helpers take the inner container as the value type")
    func dictionaryOfContainersHelpers() {
        var state = NestedContainerFieldState()
        state.updateGrid([1: 10], forKey: "row")
        state.setBuckets([["x": 1]], forKey: "k")
        state.updateNested(["y": 2], forKey: "n")
        #expect(state.grid == ["row": [1: 10]])
        #expect(state.removeGrid(forKey: "row") == [1: 10])
        #expect(state.buckets == ["k": [["x": 1]]])
        #expect(state.nested == ["n": ["y": 2]])
        #expect(state.getDirtyFields().isSuperset(of: ["grid", "buckets", "nested"]))
    }

    @Test("Labeled tuple elements and values keep their labels")
    func labeledTupleHelpers() {
        var state = NestedContainerFieldState()
        state.appendPairs((a: 1, b: 2))
        state.updateLabeled((a: 3, b: 4), forKey: 7)
        #expect(state.pairs.count == 1 && state.pairs[0].a == 1 && state.pairs[0].b == 2)
        #expect(state.labeled[7]?.b == 4)
        #expect(state.getDirtyFields().isSuperset(of: ["pairs", "labeled"]))
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
