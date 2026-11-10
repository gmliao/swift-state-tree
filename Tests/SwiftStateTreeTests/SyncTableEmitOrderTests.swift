// Tests/SwiftStateTreeTests/SyncTableEmitOrderTests.swift
//
// The typed broadcast diff emits its patches in the canonical order (`CanonicalPatchOrder`) from
// the walk itself: root fields, a row's fields and a map's changed rows in the order of their
// path components, a row's own set or delete before its fields, and the patches grouped by
// table. Nothing is sorted by parsing paths. These tests compare that output with
// `CanonicalPatchOrder.sorted` of itself, path by path and byte by byte.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct EmitOrderLeaf: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var x: Int = 0
    @Sync(.broadcast) var tags: [String: Int] = [:]

    init() {}
}

@StateNodeBuilder
struct EmitOrderHolder: StateNodeProtocol {
    @Sync(.broadcast) var inner: [String: EmitOrderLeaf] = [:]
    @Sync(.broadcast) var tag: Int = 0
    @Sync(.broadcast) var lead: EmitOrderLeaf = EmitOrderLeaf()

    init() {}
}

@StateNodeBuilder
struct EmitOrderState: StateNodeProtocol {
    @Sync(.broadcast) var byInt: [Int: EmitOrderLeaf] = [:]
    @Sync(.broadcast) var byName: [String: EmitOrderLeaf] = [:]
    @Sync(.broadcast) var holders: [String: EmitOrderHolder] = [:]
    @Sync(.broadcast) var boss: EmitOrderLeaf = EmitOrderLeaf()
    @Sync(.broadcast) var maybe: EmitOrderLeaf? = nil
    @Sync(.broadcast) var values: [String: Int] = [:]
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var zeta: Int = 0

    init() {}
}

private let nfc = "\u{e9}", nfd = "e\u{301}"
private let emitOrderNames = ["a", "a/b", "t~x", nfc, nfd, "z", "10", "9", ""]

private func leaf(_ n: Int) -> EmitOrderLeaf {
    var leaf = EmitOrderLeaf()
    leaf.hp = n
    leaf.x = -n
    return leaf
}

/// The paths as bytes: `String` equality would treat the NFC and the NFD key as one.
private func pathBytes(_ patches: [StatePatch]) -> [[UInt8]] {
    patches.map { Array($0.path.utf8) }
}

@Suite("The typed diff emits in canonical order without a sort")
struct SyncTableEmitOrderTests {
    @Test("Every typed field of the state is walked, none takes the fallback")
    func kinds() {
        let tables = SyncTableBroadcastDiff<EmitOrderState>()
        #expect(tables.kinds.values.allSatisfy { $0 != .fallback }, "\(tables.fallbackReasons)")
    }

    @Test("Int keys, an NFC and an NFD key, nested maps, a new row, a delete and two tables come out in order")
    func scriptedDiff() throws {
        var state = EmitOrderState()
        for key in [9, 10, 100, 55] { state.byInt[key] = leaf(key) }
        for name in [nfc, nfd, "a/b", "z"] { state.byName[name] = leaf(1) }
        var holder = EmitOrderHolder()
        holder.inner["k"] = leaf(2)
        holder.inner["b"] = leaf(3)
        state.holders["h"] = holder
        state.values = ["m": 1, "b": 2]

        let tables = SyncTableBroadcastDiff<EmitOrderState>()
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)

        var changed = state
        changed.byInt[9]?.hp = 90
        changed.byInt[10]?.hp = 91
        changed.byInt[10]?.x = 5
        changed.byInt[100]?.x = 7
        changed.byInt[7] = leaf(7)                 // a new row
        changed.byInt[55] = nil                    // a delete
        changed.byName[nfc]?.hp = 2
        changed.byName[nfd]?.hp = 3
        changed.byName["a/b"]?.tags["q"] = 1
        changed.byName["a/b"]?.tags["c"] = 2
        changed.holders["h"]?.tag = 4
        changed.holders["h"]?.inner["k"]?.hp = 5   // a row two maps down
        changed.holders["h"]?.inner["b"] = nil
        changed.holders["h"]?.lead.x = 6           // a node held by a row
        changed.holders["g"] = EmitOrderHolder()   // a new row in the parent table
        changed.boss.x = 8
        changed.maybe = leaf(9)                    // an optional node appears
        changed.values["a"] = 3
        changed.values["z"] = 4
        changed.round = 1
        changed.zeta = 2

        let patches = tables.diff(changed, fields: nil, drops: &drops).patches
        #expect(drops.count == 0)
        #expect(patches.count >= 20)
        let order = CanonicalPatchOrder.forState(EmitOrderState.self)
        #expect(pathBytes(patches) == pathBytes(order.sorted(patches)), "\(patches.map(\.path))")
        // The same patches as a diff that sorts.
        let sorting = SyncTableBroadcastDiff<EmitOrderState>()
        sorting.seed(state, drops: &drops)
        let sorted = SyncTableOrderForTesting.$sorts.withValue(true) {
            sorting.diff(changed, fields: nil, drops: &drops).patches
        }
        #expect(pathBytes(patches) == pathBytes(sorted))
        #expect(patches == sorted)
        // "10" before "9": byte order, not numeric order.
        let intRows = patches.map(\.path).filter { $0.hasPrefix("/byInt/") }
        #expect(intRows.first == "/byInt/10/hp")
    }

    @Test("Random mutations: each diff is in canonical order and equals the sorted diff", arguments: [false, true])
    func randomDiffs(dirtyOnly: Bool) throws {
        var generator = SystemRandomNumberGenerator()
        let seed = UInt64.random(in: 0 ... .max, using: &generator)
        var random = EmitOrderRandom(state: seed)
        var state = EmitOrderState()
        let walking = SyncTableBroadcastDiff<EmitOrderState>()
        let sorting = SyncTableBroadcastDiff<EmitOrderState>()
        let order = CanonicalPatchOrder.forState(EmitOrderState.self)
        var drops = ExtractionDrops()
        walking.seed(state, drops: &drops)
        sorting.seed(state, drops: &drops)
        for step in 0..<400 {
            var touched: Set<String> = []
            for _ in 0..<(1 + random.next(6)) {
                let name = emitOrderNames[random.next(emitOrderNames.count)]
                let n = random.next(50)
                switch random.next(14) {
                case 0: state.byInt[n % 12 + 5] = leaf(n); touched.insert("byInt")
                case 1: state.byInt[n % 12 + 5]?.hp += 1; touched.insert("byInt")
                case 2: state.byInt[n % 12 + 5] = nil; touched.insert("byInt")
                case 3: state.byName[name] = leaf(n); touched.insert("byName")
                case 4: state.byName[name]?.tags[emitOrderNames[n % emitOrderNames.count]] = n; touched.insert("byName")
                case 5: state.byName[name] = nil; touched.insert("byName")
                case 6: state.holders[name] = EmitOrderHolder(); touched.insert("holders")
                case 7: state.holders[name]?.inner[emitOrderNames[n % emitOrderNames.count]] = leaf(n); touched.insert("holders")
                case 8: state.holders[name]?.inner[emitOrderNames[n % emitOrderNames.count]]?.x += 1; touched.insert("holders")
                case 9: state.holders[name]?.lead.hp += 1; state.holders[name]?.tag += 1; touched.insert("holders")
                case 10: state.holders[name] = nil; touched.insert("holders")
                case 11: state.boss.x += 1; state.round += 1; touched.formUnion(["boss", "round"])
                case 12: state.maybe = n % 3 == 0 ? nil : leaf(n); touched.insert("maybe")
                default: state.values[name] = n % 4 == 0 ? nil : n; state.zeta += 1; touched.formUnion(["values", "zeta"])
                }
            }
            let fields = dirtyOnly ? touched : nil
            let walked = walking.diff(state, fields: fields, drops: &drops)
            let sorted = SyncTableOrderForTesting.$sorts.withValue(true) {
                sorting.diff(state, fields: fields, drops: &drops)
            }
            guard pathBytes(walked.patches) == pathBytes(order.sorted(walked.patches)),
                  pathBytes(walked.patches) == pathBytes(sorted.patches), walked.patches == sorted.patches else {
                Issue.record("seed \(seed), step \(step): walked \(walked.patches.map(\.path)) vs sorted \(sorted.patches.map(\.path))")
                return
            }
            walking.apply(walked.staged)
            sorting.apply(sorted.staged)
        }
        #expect(drops.count == 0)
    }
}

/// SplitMix64: a seed printed on failure replays the run.
private struct EmitOrderRandom {
    var state: UInt64

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
