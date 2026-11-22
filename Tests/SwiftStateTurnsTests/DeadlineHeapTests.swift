// The core's deadline heap against a sorted reference (Notes/plans/2026-11-21-turns-shared-
// deadline-timer.md §4.3 test 1). Pure: no actor, no clock. Seeded random pushes, invalidations,
// pops and rebuilds; every pop must be the reference's first valid-or-stale entry by
// (instant, arm order), and a rebuild must keep exactly the entries it is told to keep.

import SwiftStateTurns
import Testing

@Suite("The deadline heap (#621 item 2)")
struct DeadlineHeapTests {
    static let seeds: [UInt64] = Array(1 ... 24)

    @Test("Pops come in (instant, arm order) order, and a rebuild keeps exactly the kept entries", arguments: seeds)
    func matchesSortedReference(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        var heap = DeadlineHeap()
        var reference: [DeadlineEntry] = []
        var stale: Set<UInt64> = []
        var nextOrder: UInt64 = 0
        var nextTicket: UInt64 = 0

        func sorted(_ entries: [DeadlineEntry]) -> [DeadlineEntry] {
            entries.sorted { $0.precedes($1) }
        }

        for _ in 0 ..< 400 {
            switch rng.next() % 10 {
            case 0 ..< 5:
                // A small range of instants, so equal instants (arm-order ties) are common.
                let entry = DeadlineEntry(
                    instant: Int64(rng.next() % 16), order: nextOrder, ticket: nextTicket, isTimer: rng.next() % 2 == 0
                )
                nextOrder &+= 1
                nextTicket &+= 1
                heap.push(entry)
                reference.append(entry)
            case 5, 6:
                // Invalidate a random entry (lazy: it stays until popped or rebuilt).
                if let victim = reference.randomElement(using: &rng) { stale.insert(victim.ticket) }
            case 7, 8:
                let expected = sorted(reference).first
                #expect(heap.first == expected, "seed \(seed): peek")
                let popped = heap.popFirst()
                #expect(popped == expected, "seed \(seed): pop")
                if let popped { reference.removeAll { $0.ticket == popped.ticket } }
            default:
                heap.rebuild { !stale.contains($0.ticket) }
                reference.removeAll { stale.contains($0.ticket) }
                stale.removeAll()
                #expect(heap.count == reference.count, "seed \(seed): rebuild count")
            }
            #expect(heap.count == reference.count, "seed \(seed): count")
        }

        // Drain: the rest comes out in the reference's order.
        var drained: [DeadlineEntry] = []
        while let entry = heap.popFirst() { drained.append(entry) }
        #expect(drained == sorted(reference), "seed \(seed): drain order")
        #expect(heap.isEmpty)
    }

    @Test("Equal instants pop in arm order; an empty heap peeks and pops nil; removeAll empties it")
    func tiesAndEmpty() {
        var heap = DeadlineHeap()
        #expect(heap.first == nil)
        #expect(heap.popFirst() == nil)
        for (order, instant) in [(0, 9), (1, 5), (2, 9), (3, 5), (4, 12)] as [(UInt64, Int64)] {
            heap.push(DeadlineEntry(instant: instant, order: order, ticket: order, isTimer: false))
        }
        var tickets: [UInt64] = []
        while let entry = heap.popFirst() { tickets.append(entry.ticket) }
        #expect(tickets == [1, 3, 0, 2, 4])

        heap.push(DeadlineEntry(instant: 1, order: 5, ticket: 5, isTimer: true))
        heap.removeAll()
        #expect(heap.isEmpty)
    }

    @Test("A rebuild that keeps nothing, or everything, leaves a valid heap")
    func rebuildExtremes() {
        var heap = DeadlineHeap()
        for ticket in UInt64(0) ..< 100 {
            heap.push(DeadlineEntry(instant: Int64(100 - ticket), order: ticket, ticket: ticket, isTimer: false))
        }
        heap.rebuild { _ in true }
        var last = Int64.min
        var copy = heap
        while let entry = copy.popFirst() {
            #expect(entry.instant >= last)
            last = entry.instant
        }
        heap.rebuild { _ in false }
        #expect(heap.isEmpty)
    }
}
