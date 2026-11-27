// The core's deadline heap (#621 item 2, Notes/plans/2026-11-21-turns-shared-deadline-timer.md
// §3.1, §3.5): every armed request deadline, gate deadline and timer instant of one core, ordered
// by (instant, arm order), with lazy deletion. An entry is never removed when its request closes
// or its timer is replaced; the core counts it stale, and a wake drops it at the head or a
// rebuild drops it in bulk. Actor-isolated driver state: no lock.

/// What a deadline entry's ticket names.
@usableFromInline
package enum DeadlineKind: UInt8, Equatable, Sendable {
    /// A request's or a follow-up gate's deadline (`RequestID`).
    case request
    /// A key's timer (`Runtime.timerKeys`).
    case timer
    /// A barrier wait's timeout (`Runtime.barrierTimers`).
    case barrier
}

/// One armed instant. Trivial (no references), so a sift copies no reference counts.
@usableFromInline
package struct DeadlineEntry: Equatable, Sendable {
    /// `TurnInstant.nanoseconds` of the instant the entry is due at.
    @usableFromInline package var instant: Int64
    /// The core's arm counter when the entry was pushed: entries at one instant fire in arm order.
    @usableFromInline package var order: UInt64
    /// A `RequestID`'s raw value, a timer generation or a barrier timeout's generation, by
    /// `kind`. Never reused within a core and kind.
    @usableFromInline package var ticket: UInt64
    /// What `ticket` names: liveness, the fire and compaction all read it.
    @usableFromInline package var kind: DeadlineKind

    /// Whether `ticket` is a timer generation.
    @inlinable package var isTimer: Bool { kind == .timer }

    @inlinable
    package init(instant: Int64, order: UInt64, ticket: UInt64, kind: DeadlineKind) {
        self.instant = instant
        self.order = order
        self.ticket = ticket
        self.kind = kind
    }

    @inlinable
    package init(instant: Int64, order: UInt64, ticket: UInt64, isTimer: Bool) {
        self.init(instant: instant, order: order, ticket: ticket, kind: isTimer ? .timer : .request)
    }

    /// The heap order: earlier instant first, then earlier arm.
    @inlinable
    package func precedes(_ other: DeadlineEntry) -> Bool {
        instant != other.instant ? instant < other.instant : order < other.order
    }
}

/// A binary min-heap of `DeadlineEntry`, by `precedes`.
@usableFromInline
package struct DeadlineHeap: Sendable {
    @usableFromInline package var storage: [DeadlineEntry] = []

    @inlinable package init() {}

    @inlinable package var count: Int { storage.count }
    @inlinable package var isEmpty: Bool { storage.isEmpty }

    /// The entry due first, without removing it.
    @inlinable package var first: DeadlineEntry? { storage.first }

    @inlinable
    package mutating func push(_ entry: DeadlineEntry) {
        storage.append(entry)
        siftUp(storage.count - 1)
    }

    /// Removes and returns the entry due first.
    @inlinable
    package mutating func popFirst() -> DeadlineEntry? {
        guard !storage.isEmpty else { return nil }
        let last = storage.removeLast()
        guard !storage.isEmpty else { return last }
        let head = storage[0]
        storage[0] = last
        siftDown(0)
        return head
    }

    /// Keeps only the entries `isKept` accepts and restores the heap order in O(n) (Floyd's
    /// bottom-up heapify), keeping the storage's capacity.
    @inlinable
    package mutating func rebuild(keeping isKept: (DeadlineEntry) -> Bool) {
        storage.removeAll(where: { !isKept($0) })
        guard storage.count > 1 else { return }
        var index = storage.count / 2 - 1
        while index >= 0 {
            siftDown(index)
            index -= 1
        }
    }

    /// Drops every entry, keeping the storage's capacity.
    @inlinable
    package mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }

    @inlinable
    package mutating func siftUp(_ start: Int) {
        var child = start
        let entry = storage[child]
        while child > 0 {
            let parent = (child - 1) / 2
            guard entry.precedes(storage[parent]) else { break }
            storage[child] = storage[parent]
            child = parent
        }
        storage[child] = entry
    }

    @inlinable
    package mutating func siftDown(_ start: Int) {
        let count = storage.count
        var parent = start
        let entry = storage[parent]
        while true {
            let left = 2 * parent + 1
            guard left < count else { break }
            let right = left + 1
            let child = right < count && storage[right].precedes(storage[left]) ? right : left
            guard storage[child].precedes(entry) else { break }
            storage[parent] = storage[child]
            parent = child
        }
        storage[parent] = entry
    }
}
