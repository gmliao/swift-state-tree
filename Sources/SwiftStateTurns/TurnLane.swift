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
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var reports: [(sequence: UInt64, report: Report)] = []
    private var head = 0
    /// `reports.count - head`, kept as a plain `Int` so `isEmpty` and the capacity check don't
    /// touch the generic array: in the unspecialized class each array access looks up the
    /// element tuple's metadata at run time.
    private var count = 0
    private var lastSequence: UInt64 = 0
    private var refusals = 0
    /// How many reports the lane holds at once; a post past it is refused. Also the budget of
    /// reports one entry steps (`TurnCore.init`'s `laneCapacity:`).
    public let capacity: Int

    @usableFromInline init(capacity: Int) {
        // `fatalError`, not `precondition`: its message prints in release builds too.
        if capacity < 1 { fatalError("TurnLane: capacity must be at least 1") }
        self.capacity = capacity
    }

    /// Appends `report`, unless the lane is full: then it counts a refusal and returns nil.
    /// Otherwise returns whether the lane was empty, read in the same critical section as the
    /// append, so only the post that makes the lane non-empty owns its wake.
    @usableFromInline func append(_ report: Report) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if count >= capacity {
            refusals += 1
            return nil
        }
        let wasEmpty = count == 0
        lastSequence &+= 1
        reports.append((lastSequence, report))
        count += 1
        return wasEmpty
    }

    /// True when the lane holds no report.
    @usableFromInline var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }

    /// The sequence number of the last report posted: a check's watermark.
    @usableFromInline var watermark: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastSequence
    }

    /// Removes and returns the head, if its sequence number is at or below `watermark`.
    @usableFromInline func removeHead(atOrBelow watermark: UInt64) -> Report? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0, reports[head].sequence <= watermark else { return nil }
        let report = reports[head].report
        head += 1
        count -= 1
        if count == 0 {
            reports.removeAll(keepingCapacity: true)
            head = 0
        }
        return report
    }

    /// Removes and returns every report the lane holds, from the head.
    @usableFromInline func removeAll() -> [Report] {
        lock.lock()
        defer { lock.unlock() }
        if count == 0 { return [] }
        let taken = reports[head...].map(\.report)
        reports.removeAll(keepingCapacity: true)
        head = 0
        count = 0
        return taken
    }

    /// How many posts the lane has refused since it was made.
    @usableFromInline var refusedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return refusals
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
