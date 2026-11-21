import Foundation
import SwiftStateTurns
import Testing

/// A report that runs `onDeinit` when it is released: a `deinit` that posts to the lane that
/// held it.
final class DeinitReport: Sendable {
    let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void = {}) {
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }
}

/// The lane's storage (plan §3.5, rev 4): a ring of `capacity` slots, with removed reports
/// released after the lock is dropped.
@Suite("Lane storage")
struct LaneStorageTests {
    @Test("19: sustained turnover with the lane never empty keeps the storage at capacity")
    func ringStaysBounded() {
        let lane = TurnLane<Int>(capacity: 2)
        _ = lane.append(0)
        for i in 1 ... 10_000 {
            #expect(lane.append(i) == false)
            #expect(lane.removeHead(atOrBelow: lane.watermark) == i - 1)
        }
        #expect(lane.slotCountForTesting == 2)
        // Only the report still pending is held: a stepped report's slot is empty.
        #expect(lane.heldReportsForTesting == 1)
        #expect(lane.removeAll() == [10_000])
        #expect(lane.heldReportsForTesting == 0)
    }

    @Test("19: a check's watermark still stops at a report posted after it, across the ring's wrap")
    func watermarkAcrossTheWrap() {
        let lane = TurnLane<Int>(capacity: 3)
        for i in 1 ... 5 {
            _ = lane.append(i)
            _ = lane.removeHead(atOrBelow: lane.watermark)
        }
        _ = lane.append(6)
        let watermark = lane.watermark
        _ = lane.append(7)
        #expect(lane.removeHead(atOrBelow: watermark) == 6)
        #expect(lane.removeHead(atOrBelow: watermark) == nil)
        #expect(lane.removeHead(atOrBelow: lane.watermark) == 7)
        #expect(lane.isEmpty)
    }

    @Test("20: a report whose deinit posts to the same lane is removed and released without a deadlock")
    func releaseOutsideTheLock() {
        let lane = TurnLane<DeinitReport>(capacity: 2)
        _ = lane.append(DeinitReport(onDeinit: { _ = lane.append(DeinitReport()) }))
        // The removed report is released here, after `removeHead` dropped the lock.
        _ = lane.removeHead(atOrBelow: lane.watermark)
        #expect(!lane.isEmpty)
        // The same through `removeAll`, the take's path.
        _ = lane.removeAll()
        _ = lane.append(DeinitReport(onDeinit: { _ = lane.append(DeinitReport()) }))
        _ = lane.removeAll()
        #expect(lane.removeAll().count == 1)
        #expect(lane.isEmpty)
    }
}
