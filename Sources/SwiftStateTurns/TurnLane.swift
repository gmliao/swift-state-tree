// The core's post lane: reports from any thread, taken before the next step.

import Foundation

/// The reports posted to a core from any thread, in post order, each with the sequence number
/// the lane gave it at its post. The core makes it (`TurnCore.lane`), and its actor stores the
/// same instance (`TurnActor.lane`), so `post` reaches it without the actor's isolation.
///
/// The driver takes the lane before every step. A check reads the last sequence number (its
/// watermark) and removes the head one report at a time while the head is at or below it, so
/// a report posted during the check waits for the next one, and a step's own
/// `Turn.takeReports()` takes from the same queue, in order.
public final class TurnLane<Report: Sendable>: @unchecked Sendable {
    @usableFromInline let lock = NSLock()
    /// A ring of `capacity` slots, guarded by `lock`. Accepted posts are numbered one after
    /// another and removed in order, so the head's sequence number is
    /// `lastSequence - count + 1` and no slot stores one. A removal moves its report out and
    /// leaves the slot empty, so the lane never holds a report it has handed out.
    private var slots: [Report?]
    private var head = 0
    /// How many reports the lane holds, guarded by `lock`. A plain `Int`, so `isEmpty` and the
    /// capacity check touch no generic storage (unspecialized, each access to it would look up
    /// metadata at run time).
    @usableFromInline var count = 0
    private var lastSequence: UInt64 = 0
    private var refusals = 0
    /// How many reports the lane holds at once; a post past it is refused. Also the budget of
    /// reports one entry steps (`TurnCore.init`'s `laneCapacity:`).
    public let capacity: Int

    @usableFromInline package init(capacity: Int) {
        // `fatalError`, not `precondition`: its message prints in release builds too.
        if capacity < 1 { fatalError("TurnLane: capacity must be at least 1") }
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }

    /// Appends `report`, unless the lane is full: then it counts a refusal and returns nil.
    /// Otherwise returns whether the lane was empty, read in the same critical section as the
    /// append, so only the post that makes the lane non-empty owns its wake.
    @usableFromInline package func append(_ report: Report) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if count >= capacity {
            refusals += 1
            return nil
        }
        let wasEmpty = count == 0
        lastSequence &+= 1
        slots[(head + count) % capacity] = report
        count += 1
        return wasEmpty
    }

    /// True when the lane holds no report.
    @inlinable package var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }

    /// The sequence number of the last report posted: a check's watermark.
    @usableFromInline package var watermark: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastSequence
    }

    /// Removes and returns the head, if its sequence number is at or below `watermark`. The
    /// report is moved out of its slot, so it is released by the caller, after the lock is
    /// dropped: a report whose `deinit` posts to this lane can't deadlock on it.
    @usableFromInline package func removeHead(atOrBelow watermark: UInt64) -> Report? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0, lastSequence &- UInt64(count) &+ 1 <= watermark else { return nil }
        let report = slots[head].take()
        head = (head + 1) % capacity
        count -= 1
        return report
    }

    /// Removes and returns every report the lane holds, from the head; released by the caller,
    /// after the lock is dropped.
    @usableFromInline package func removeAll() -> [Report] {
        lock.lock()
        defer { lock.unlock() }
        if count == 0 { return [] }
        var taken: [Report] = []
        taken.reserveCapacity(count)
        while count > 0 {
            if let report = slots[head].take() { taken.append(report) }
            head = (head + 1) % capacity
            count -= 1
        }
        return taken
    }

    /// How many posts the lane has refused since it was made.
    @usableFromInline package var refusedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return refusals
    }

    /// The slots the lane's storage holds, stepped or not: always `capacity`.
    package var slotCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
    }

    /// The reports the storage still holds: never more than `count`.
    package var heldReportsForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }
}

// MARK: - Recording and replay

/// Where the core handed out a lane report, named by the steps it dispatches, so a replay
/// puts each report back at the same place. `step` is a dispatched step's ordinal, counted from
/// the core's start over every non-report step.
/// - `before(step: n, index: i)`: the i-th report a check stepped before step n's dispatch.
/// - `inside(step: n, take: t)`: what take t of step n's `Turn.takeReports()` returned.
///
/// Keys sort by step, then `before` ahead of `inside`, then index or take: the order a replay
/// consumes them in.
@usableFromInline
package enum LaneRecordKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    case before(step: UInt64, index: Int)
    case inside(step: UInt64, take: Int)

    @inlinable @usableFromInline package var step: UInt64 {
        switch self {
        case .before(let step, _), .inside(let step, _): return step
        }
    }

    @inlinable var order: (UInt64, Int, Int) {
        switch self {
        case .before(let step, let index): return (step, 0, index)
        case .inside(let step, let take): return (step, 1, take)
        }
    }

    @inlinable @usableFromInline package static func < (lhs: LaneRecordKey, rhs: LaneRecordKey) -> Bool {
        lhs.order < rhs.order
    }

    @usableFromInline package var description: String {
        switch self {
        case .before(let step, let index): return "before(\(step), \(index))"
        case .inside(let step, let take): return "inside(\(step), \(take))"
        }
    }
}

/// One recorded hand-out: the reports at `key` and, for a `before` key, the `now` of the check
/// that stepped it, which a replay serves inside that report's step.
@usableFromInline
package struct LaneRecordEntry<Report: Sendable>: Sendable {
    @usableFromInline package var key: LaneRecordKey
    @usableFromInline package var reports: [Report]
    @usableFromInline package var now: TurnInstant?

    @usableFromInline package init(key: LaneRecordKey, reports: [Report], now: TurnInstant?) {
        self.key = key
        self.reports = reports
        self.now = now
    }
}

/// A replay that doesn't match its record.
@usableFromInline
package enum TurnReplayDivergence: Error, Equatable, Sendable {
    /// Step n dispatched while an entry for an earlier place was still staged: a step took
    /// fewer times than recorded, or a check stepped fewer reports.
    case unconsumed(LaneRecordKey)
    /// An entry still staged after `finishReplay()`.
    case leftover(LaneRecordKey)
}

/// A replay's staged hand-outs, consumed in key order.
@usableFromInline
struct LaneReplayStage<Report: Sendable> {
    @usableFromInline var entries: [LaneRecordEntry<Report>]
    @usableFromInline var head = 0

    @inlinable init(_ entries: [LaneRecordEntry<Report>]) {
        self.entries = entries.sorted { $0.key < $1.key }
    }

    @inlinable var first: LaneRecordEntry<Report>? { head < entries.count ? entries[head] : nil }

    @inlinable mutating func removeFirst() { head += 1 }
}
