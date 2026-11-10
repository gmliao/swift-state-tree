// The slotted last-sent table of a root node map (row addressing, PR B): slot allocation,
// staging and the slot tags on patches. The frames are unchanged; the differential and
// byte-identity suites cover that.

import Foundation
import Testing
@testable import SwiftStateTree

private typealias Table = SyncSlottedTable<String, Int>
private typealias Plan = SyncRowPlan<String, Int>

private func identity(_ key: String) -> String { key }

/// The table's rows by slot, as (key, row, generation); nil for a free slot.
private func layout(_ table: Table) -> [String?] {
    table.keys.indices.map { slot in
        table.keys[slot].map { "\($0)=\(table.rows[slot]!)#\(table.generation(of: Int32(slot)))" }
    }
}

/// A plan creating `keys` (already in component order) at the slots the table plans.
private func creating(_ keys: [String], in table: Table, value: Int = 0) -> Plan {
    var plan = Plan()
    for (key, slot) in zip(keys, table.plannedSlots(creating: keys.count)) {
        plan.creates.append((slot, key, value))
    }
    return plan
}

@Suite("Slotted last-sent table")
struct SyncSlottedTableTests {
    @Test("A seed numbers its rows from 0 in the order of their key bytes")
    func seedOrder() {
        let table = Table(seeding: ["b": 2, "10": 10, "9": 9, "a/b": 1, "": 0], keyString: identity)
        // "" < "10" < "9" < "a~1b" < "b": bytes of the escaped component, not numeric order.
        #expect(layout(table) == ["=0#0", "10=10#0", "9=9#0", "a/b=1#0", "b=2#0"])
        #expect(table.count == 5)
        #expect(table.free.isEmpty)
        #expect(table.dictionary == ["b": 2, "10": 10, "9": 9, "a/b": 1, "": 0])
    }

    @Test("New rows take the lowest free slots, then new ones; a freed slot comes back with the next generation")
    func allocation() {
        var table = Table(seeding: ["a": 1, "b": 2, "c": 3, "d": 4], keyString: identity)
        var plan = Plan()
        plan.deletes = [1, 3]
        table.commit(plan)
        #expect(layout(table) == ["a=1#0", nil, "c=3#0", nil])
        #expect(table.free == [1, 3])
        #expect(table.plannedSlots(creating: 0) == [])
        #expect(table.plannedSlots(creating: 1) == [1])
        #expect(table.plannedSlots(creating: 3) == [1, 3, 4])

        let planned = creating(["x", "y", "z"], in: table, value: 7)
        #expect(planned.creates.map(\.slot) == [1, 3, 4])
        table.commit(planned)
        #expect(layout(table) == ["a=1#0", "x=7#1", "c=3#0", "y=7#1", "z=7#0"])
        #expect(table.free.isEmpty)
        #expect(table.index == ["a": 0, "x": 1, "c": 2, "y": 3, "z": 4])
    }

    @Test("A slot freed by a plan is not taken by a create of the same plan")
    func noReuseInsideAPlan() {
        var table = Table(seeding: ["a": 1, "b": 2], keyString: identity)
        // Planned against the committed table: "b"'s slot is not free yet.
        var plan = creating(["n"], in: table, value: 9)
        plan.deletes = [1]
        #expect(plan.creates.map(\.slot) == [2])
        table.commit(plan)
        #expect(layout(table) == ["a=1#0", nil, "n=9#0"])
        // From the next plan on it is.
        #expect(table.plannedSlots(creating: 1) == [1])
        table.commit(creating(["m"], in: table))
        #expect(layout(table) == ["a=1#0", "m=0#1", "n=9#0"])
    }

    @Test("A create dropped from a plan leaves the kept creates at their planned slots")
    func droppedCreate() {
        var table = Table(seeding: ["k0": 0, "k1": 1, "k2": 2, "k3": 3, "k4": 4, "k5": 5], keyString: identity)
        var free = Plan()
        free.deletes = [3, 5]
        table.commit(free)
        // "a" and "b" are planned at 3 and 5; "a" is dropped after the frame was written.
        var plan = creating(["a", "b"], in: table)
        #expect(plan.creates.map(\.slot) == [3, 5])
        plan.creates.removeFirst()
        table.commit(plan)
        #expect(table.index["b"] == 5, "b stays where the frame put it")
        #expect(table.index["a"] == nil)
        #expect(table.free == [3])

        // Past the end: the skipped slot is free, with no generation used.
        var tail = creating(["p", "q", "r"], in: table)
        #expect(tail.creates.map(\.slot) == [3, 6, 7])
        tail.creates.remove(at: 1)
        table.commit(tail)
        #expect(table.index["p"] == 3 && table.index["r"] == 7)
        #expect(table.free == [6])
        table.commit(creating(["s"], in: table))
        #expect(table.index["s"] == 6)
        #expect(table.generation(of: 6) == 0, "the skipped slot's first row")
        #expect(table.generation(of: 3) == 1)
    }

    @Test("Updates write rows in place; a plan that is not committed changes nothing")
    func updatesAndDiscardedPlans() {
        var table = Table(seeding: ["a": 1, "b": 2], keyString: identity)
        let before = layout(table)
        var discarded = creating(["z"], in: table)
        discarded.updates = [(0, 100)]
        discarded.deletes = [1]
        // Not committed: the table is a value the plan never touched.
        #expect(layout(table) == before)
        #expect(table.plannedSlots(creating: 1) == [2])

        var plan = Plan()
        plan.updates = [(1, 20)]
        table.commit(plan)
        #expect(layout(table) == ["a=1#0", "b=20#0"])
    }

    @Test("Random plans: the table equals a native map, and its bookkeeping stays consistent")
    func randomPlans() {
        var generator = SystemRandomNumberGenerator()
        let seed = UInt64.random(in: 0 ... .max, using: &generator)
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var table = Table()
        var shadow: [String: Int] = [:]
        var generations: [Int32: UInt32] = [:]
        for step in 0..<600 {
            var plan = Plan()
            var newKeys: Set<String> = []
            var touched: Set<String> = []
            for _ in 0..<next(5) {
                let key = "k\(next(24))"
                guard touched.insert(key).inserted else { continue }
                if let slot = table.index[key] {
                    if next(2) == 0 {
                        plan.deletes.append(slot)
                        shadow[key] = nil
                    } else {
                        plan.updates.append((slot, step))
                        shadow[key] = step
                    }
                } else {
                    newKeys.insert(key)
                    shadow[key] = step
                }
            }
            let ordered = newKeys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (key, slot) in zip(ordered, table.plannedSlots(creating: ordered.count)) {
                plan.creates.append((slot, key, step))
                #expect(!plan.deletes.contains(slot), "seed \(seed): a create in a slot its plan frees")
            }
            let planned = plan.creates.map(\.slot)
            table.commit(plan)

            #expect(table.dictionary == shadow, "seed \(seed), step \(step)")
            #expect(table.count == shadow.count)
            #expect(planned == plan.creates.map { table.index[$0.key]! }, "seed \(seed): the commit lands on the planned slots")
            #expect(table.free == table.free.sorted())
            for slot in table.rows.indices {
                let occupied = table.rows[slot] != nil
                #expect(occupied == (table.keys[slot] != nil))
                #expect(occupied != table.free.contains(Int32(slot)), "seed \(seed): slot \(slot) is free or occupied, not both")
                if let key = table.keys[slot] {
                    #expect(table.index[key] == Int32(slot))
                    let generation = table.generation(of: Int32(slot))
                    #expect(generation >= generations[Int32(slot)] ?? 0, "seed \(seed): a generation went down")
                    generations[Int32(slot)] = generation
                }
            }
        }
    }
}

// MARK: - Through the typed diff

private func slots(_ tables: SyncTableBroadcastDiff<TableRoot>, _ field: String) -> [String: Int32] {
    (tables.rowSlotsForTesting(field) ?? [:]).mapValues(\.slot)
}

@Suite("Slotted tables in the typed diff")
struct SyncSlottedTableDiffTests {
    @Test("A root node map is slotted: seeded in key order, new rows in key order, a delete's slot free from the next plan")
    func slotsThroughTheDiff() {
        var state = TableRoot()
        for key in [9, 10, 100] { state.rows[key] = TableRow() }
        let tables = SyncTableBroadcastDiff<TableRoot>()
        var drops = ExtractionDrops()
        #expect(tables.rowSlotsForTesting("rows") == nil, "unseeded")
        tables.seed(state, drops: &drops)
        // "10" < "100" < "9" by bytes.
        #expect(slots(tables, "rows") == ["10": 0, "100": 1, "9": 2])
        #expect(tables.rowSlotsForTesting("score") == nil, "a value field has no slots")

        // One plan: a delete and two creates. The creates don't take the deleted row's slot.
        state.rows[100] = nil
        state.rows[7] = TableRow()
        state.rows[55] = TableRow()
        let first = tables.diff(state, fields: nil, drops: &drops)
        #expect(slots(tables, "rows") == ["10": 0, "100": 1, "9": 2], "staged, not applied")
        tables.apply(first.staged)
        #expect(slots(tables, "rows") == ["10": 0, "9": 2, "55": 3, "7": 4])

        // The next plan takes the freed slot, with the next generation.
        state.rows[1] = TableRow()
        tables.apply(tables.diff(state, fields: nil, drops: &drops).staged)
        #expect(tables.rowSlotsForTesting("rows")?["1"] == SyncRowSlotForTesting(slot: 1, generation: 1))
        #expect(tables.rowSlotsForTesting("rows")?["10"] == SyncRowSlotForTesting(slot: 0, generation: 0))
        #expect(drops.count == 0)
    }

    @Test("A failed plan leaves the slots as they were, and the next plan allocates the same ones")
    func failedPlan() {
        var state = TableRoot()
        state.rows[1] = TableRow()
        state.rows[2] = TableRow()
        let tables = SyncTableBroadcastDiff<TableRoot>()
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        let before = tables.rowSlotsForTesting("rows")

        state.rows[1] = nil
        state.rows[3] = TableRow()
        let failed = tables.diff(state, fields: nil, drops: &drops)
        #expect(!failed.staged.isEmpty)
        // Dropped, as a failed sync drops it.
        #expect(tables.rowSlotsForTesting("rows") == before)

        let again = tables.diff(state, fields: nil, drops: &drops)
        #expect(again.patches == failed.patches)
        tables.apply(again.staged)
        #expect(slots(tables, "rows") == ["2": 1, "3": 2])
    }

    @Test("A field whose conversion throws stages no slot")
    func droppedField() {
        var state = TableRoot()
        state.named["a"] = TableRow()
        let tables = SyncTableBroadcastDiff<TableRoot>()
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        state.named["b"] = TableRow()
        state.named["b"]?.bad.n = -1
        let result = tables.diff(state, fields: ["named"], drops: &drops)
        #expect(drops.count == 1)
        #expect(result.patches.isEmpty)
        tables.apply(result.staged)
        #expect(slots(tables, "named") == ["a": 0])
    }

    @Test("The two spellings of a key are one row in one slot")
    func oneSlotPerKey() {
        let nfc = "\u{E9}", nfd = "e\u{301}"
        var state = TableRoot()
        state.named[nfc] = TableRow()
        state.named["z"] = TableRow()
        let tables = SyncTableBroadcastDiff<TableRoot>()
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        let seeded = tables.rowSlotsForTesting("named")
        state.named.removeValue(forKey: nfc)
        state.named[nfd] = TableRow()
        state.named[nfd]?.hp = 3
        let result = tables.diff(state, fields: nil, drops: &drops)
        #expect(result.patches.map(\.path) == ["/named/\(nfc)/hp"])
        tables.apply(result.staged)
        #expect(tables.rowSlotsForTesting("named") == seeded)
    }

    @Test("With a path cursor, a patch at or below a row carries the row's slot; other patches carry none")
    func slotTags() throws {
        let hasher = PathHasher(pathHashes: [
            "score": 1, "rows": 2, "rows.*": 3, "rows.*.hp": 4, "rows.*.inner": 5, "rows.*.inner.*": 6,
            "rows.*.inner.*.v": 7, "base": 8, "base.v": 9, "rows.*.tags": 10,
        ])
        var state = TableRoot()
        for key in [1, 2, 3] { state.rows[key] = TableRow() }
        state.rows[2]?.inner["x"] = TableLeaf()
        let tables = SyncTableBroadcastDiff<TableRoot>(pathCursor: hasher.rootCursor)
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        #expect(slots(tables, "rows") == ["1": 0, "2": 1, "3": 2])

        state.score = 5
        state.base.v = 6
        state.rows[1]?.hp = 7                 // a leaf of row 1
        state.rows[2]?.inner["x"]?.v = 8      // below a nested map of row 2
        state.rows[3] = nil                   // a delete
        state.rows[40] = TableRow()           // creates, in key order: "40" then "5"
        state.rows[5] = TableRow()
        let result = tables.diff(state, fields: nil, drops: &drops)
        var tags: [String: Int32?] = [:]
        var keyCounts: [String: Int] = [:]
        for patch in result.patches {
            let split = try #require(patch.split, "\(patch.path) carries its split")
            tags[patch.path] = split.rowSlot
            keyCounts[patch.path] = split.dynamicKeys.count
        }
        #expect(tags == [
            "/score": nil, "/base/v": nil,
            "/rows/1/hp": 0,
            "/rows/2/inner/x/v": 1,
            "/rows/3": 2,
            "/rows/40": 3, "/rows/5": 4,
        ])
        // One dynamic key: the row or a leaf of it. Two: below a nested map, not a leaf.
        #expect(keyCounts["/rows/1/hp"] == 1 && keyCounts["/rows/2/inner/x/v"] == 2)
        tables.apply(result.staged)
        #expect(slots(tables, "rows") == ["1": 0, "2": 1, "40": 3, "5": 4])

        // Without a cursor there is no split and no tag; the slots are the same.
        let plain = SyncTableBroadcastDiff<TableRoot>()
        var plainState = TableRoot()
        plainState.rows[1] = TableRow()
        plain.seed(plainState, drops: &drops)
        plainState.rows[2] = TableRow()
        let untagged = plain.diff(plainState, fields: nil, drops: &drops)
        #expect(untagged.patches.allSatisfy { $0.split == nil })
        plain.apply(untagged.staged)
        #expect(slots(plain, "rows") == ["1": 0, "2": 1])
    }

    @Test("A node map nested inside a row keeps its native map: no slots of its own")
    func nestedMapIsNotSlotted() {
        var state = TableRoot()
        state.rows[1] = TableRow()
        state.rows[1]?.inner["x"] = TableLeaf()
        let tables = SyncTableBroadcastDiff<TableRoot>()
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        state.rows[1]?.inner["y"] = TableLeaf()
        state.rows[1]?.inner["x"] = nil
        let result = tables.diff(state, fields: nil, drops: &drops)
        #expect(Set(result.patches.map(\.path)) == ["/rows/1/inner/x", "/rows/1/inner/y"])
        tables.apply(result.staged)
        #expect(slots(tables, "rows") == ["1": 0])
        let last = tables.lastSentForTesting("rows") as? [Int: TableRow]
        #expect(last?[1]?.inner.keys.sorted() == ["y"])
    }
}
