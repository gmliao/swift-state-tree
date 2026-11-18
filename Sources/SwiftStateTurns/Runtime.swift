// The core's own state: lifetimes, requests, holds, parked inputs and what a step leaves for the
// driver. A value type in a stored property of the core, beside the machine, so a step changes
// both without an overlapping access.

@usableFromInline
struct FIFO<T> {
    @usableFromInline var items: [T] = []
    @usableFromInline var head = 0

    @inlinable init() {}

    @inlinable var isEmpty: Bool { head == items.count }
    @inlinable var count: Int { items.count - head }

    @inlinable mutating func push(_ item: T) { items.append(item) }

    @inlinable mutating func pop() -> T? {
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        }
        return item
    }

    /// Removes the items `predicate` picks, keeping the order of the rest; returns them.
    @inlinable mutating func remove(where predicate: (T) -> Bool) -> [T] {
        var kept: [T] = []
        var removed: [T] = []
        for item in items[head...] {
            if predicate(item) { removed.append(item) } else { kept.append(item) }
        }
        if !removed.isEmpty {
            items = kept
            head = 0
        }
        return removed
    }
}

@usableFromInline
struct RequestRecord<Key: Hashable & Sendable> {
    @usableFromInline var key: Key
    @usableFromInline var hold: Key?
    @usableFromInline var untilRetire: Bool
    /// A deadline task was armed for it.
    @usableFromInline var hasDeadline: Bool

    @inlinable init(key: Key, hold: Key?, untilRetire: Bool, hasDeadline: Bool) {
        self.key = key
        self.hold = hold
        self.untilRetire = untilRetire
        self.hasDeadline = hasDeadline
    }
}

@usableFromInline
struct Parked<M: TurnMachine> {
    @usableFromInline var input: M.Input
    @usableFromInline var caller: InputID?
    @usableFromInline var scope: M.Key?
    @usableFromInline var token: EndToken?
    /// Queued by a step (`Turn.queue`): `close`, scopes and the parked limit don't apply.
    @usableFromInline var pinned: Bool

    @inlinable init(input: M.Input, caller: InputID?, scope: M.Key?, token: EndToken?, pinned: Bool = false) {
        self.input = input
        self.caller = caller
        self.scope = scope
        self.token = token
        self.pinned = pinned
    }
}

/// An effect for the driver to launch, with its request and deadline instant.
@usableFromInline
struct PendingEffect<M: TurnMachine> {
    @usableFromInline var effect: M.Effect
    @usableFromInline var request: RequestID?
    @usableFromInline var deadline: TurnInstant?

    @inlinable init(effect: M.Effect, request: RequestID?, deadline: TurnInstant?) {
        self.effect = effect
        self.request = request
        self.deadline = deadline
    }
}

/// A timer for the driver to arm.
@usableFromInline
struct PendingTimer<M: TurnMachine> {
    @usableFromInline var key: M.Key
    @usableFromInline var generation: UInt64
    @usableFromInline var instant: TurnInstant
    @usableFromInline var input: M.Input

    @inlinable init(key: M.Key, generation: UInt64, instant: TurnInstant, input: M.Input) {
        self.key = key
        self.generation = generation
        self.instant = instant
        self.input = input
    }
}

@usableFromInline
struct Runtime<M: TurnMachine> {
    // Lifetimes.
    @usableFromInline var counter: UInt64 = 0
    @usableFromInline var live: [M.Key: UInt64] = [:]
    // Requests and the holds they own.
    @usableFromInline var nextRequest: UInt64 = 0
    @usableFromInline var open: [RequestID: RequestRecord<M.Key>] = [:]
    /// Closed requests whose worker still keeps a hold (`Hold.untilWorkerRetires`).
    @usableFromInline var retiring: [RequestID: M.Key] = [:]
    /// Hold key → how many open requests (or unretired workers) own it.
    @usableFromInline var held: [M.Key: Int] = [:]
    /// Set when a request with a deadline task closed: the driver cancels the closed ones' tasks.
    @usableFromInline var deadlinesToCancel = false
    // Timers: the current one per key, by generation.
    @usableFromInline var nextTimer: UInt64 = 0
    @usableFromInline var timers: [M.Key: UInt64] = [:]
    @usableFromInline var timersToArm: [PendingTimer<M>] = []
    /// Set when a timer was replaced or dropped: the driver cancels the stale ones' tasks.
    @usableFromInline var timersToCancel = false
    // Parked external inputs, by hold key.
    @usableFromInline var parked: [M.Key: FIFO<Parked<M>>] = [:]
    @usableFromInline var parkedCount = 0
    /// Inputs parked so far (for the diagnostics hook).
    @usableFromInline var parkEvents = 0
    /// Hold keys released while inputs were parked behind them.
    @usableFromInline var releasable: [M.Key] = []
    // What a step leaves for the driver.
    @usableFromInline var effects: [PendingEffect<M>] = []
    @usableFromInline var outputs: [M.Output] = []
    @usableFromInline var replies: [(InputID, Result<M.Reply, any Error>)] = []
    @usableFromInline var repliesAfter: [RequestID: [(InputID, Result<M.Reply, any Error>)]] = [:]
    @usableFromInline var abandoned: [(RequestID, Abandonment)] = []
    @usableFromInline var withdrawn: [InputID] = []
    @usableFromInline var closing = false
    @usableFromInline var closed = false
    /// Set by anything that leaves work for the driver; the only check after an idle step.
    @usableFromInline var dirty = false
    @usableFromInline var droppedOutputs = 0
    /// Set by `endAll`: the core is terminal, and no key can be issued again.
    @usableFromInline var ended = false
    /// `issue` and `queue` calls made after the end, and ignored.
    @usableFromInline var ignoredAfterEnd = 0

    @inlinable init() {}

    @inlinable mutating func releaseHold(_ key: M.Key) {
        guard let owners = held[key] else { return }
        if owners > 1 {
            held[key] = owners - 1
            return
        }
        held.removeValue(forKey: key)
        if let queue = parked[key], !queue.isEmpty, !releasable.contains(key) {
            releasable.append(key)
        }
        dirty = true
    }

    /// Closes a request. `why` nil: its completion arrived.
    @inlinable mutating func closeRequest(_ id: RequestID, _ why: Abandonment?) {
        guard let record = open.removeValue(forKey: id) else { return }
        if record.hasDeadline { deadlinesToCancel = true }
        if let hold = record.hold {
            if record.untilRetire, why != nil {
                retiring[id] = hold
            } else {
                releaseHold(hold)
            }
        }
        if let why {
            abandoned.append((id, why))
            if let waiting = repliesAfter.removeValue(forKey: id) {
                replies.append(contentsOf: waiting)
            }
        }
        dirty = true
    }

    @inlinable mutating func closeRequests(of key: M.Key) {
        if open.isEmpty { return }
        let ids = open.filter { $0.value.key == key }.map(\.key).sorted { $0.raw < $1.raw }
        for id in ids { closeRequest(id, .keyEnded) }
    }

    @inlinable mutating func dropTimer(of key: M.Key) {
        if timers.removeValue(forKey: key) != nil {
            timersToCancel = true
            dirty = true
        }
    }

    /// The worker of a closed request returned: a hold it kept is released.
    @inlinable mutating func retire(_ id: RequestID) {
        if let hold = retiring.removeValue(forKey: id) { releaseHold(hold) }
    }

    /// Removes the parked inputs `predicate` picks. Their callers are answered `withdrawn`.
    @inlinable mutating func withdraw(where predicate: (Parked<M>) -> Bool) {
        if parkedCount == 0 { return }
        for key in Array(parked.keys) {
            guard var queue = parked[key] else { continue }
            let removed = queue.remove(where: predicate)
            if removed.isEmpty { continue }
            parkedCount -= removed.count
            for item in removed {
                if let caller = item.caller { withdrawn.append(caller) }
            }
            parked[key] = queue.isEmpty ? nil : queue
            dirty = true
        }
    }

    /// Removes a cancelled caller's parked input, if it is still parked.
    @inlinable mutating func withdraw(caller: InputID) -> Bool {
        if parkedCount == 0 { return false }
        for key in Array(parked.keys) {
            guard var queue = parked[key] else { continue }
            let removed = queue.remove { $0.caller == caller }
            if removed.isEmpty { continue }
            parkedCount -= removed.count
            parked[key] = queue.isEmpty ? nil : queue
            return true
        }
        return false
    }

    /// Drops every parked external input (`close`) and returns their callers. What a step
    /// queued itself stays, in its order.
    @inlinable mutating func dropAllParked() -> [InputID] {
        var callers: [InputID] = []
        var kept: [M.Key: FIFO<Parked<M>>] = [:]
        var keptCount = 0
        for (key, queue) in parked {
            var keep = FIFO<Parked<M>>()
            for item in queue.items[queue.head...] {
                if item.pinned {
                    keep.push(item)
                    keptCount += 1
                } else if let caller = item.caller {
                    callers.append(caller)
                }
            }
            if !keep.isEmpty { kept[key] = keep }
        }
        parked = kept
        parkedCount = keptCount
        releasable.removeAll { kept[$0] == nil }
        return callers
    }

    @inlinable func isBlocked(_ key: M.Key) -> Bool {
        if held.isEmpty && parkedCount == 0 { return false }
        if held[key] != nil { return true }
        if let queue = parked[key] { return !queue.isEmpty }
        return false
    }

    @inlinable mutating func park(_ item: Parked<M>, behind key: M.Key) {
        parked[key, default: FIFO()].push(item)
        parkedCount += 1
    }

    /// The next key whose parked inputs may step: released, not held again, not empty.
    @inlinable mutating func nextReleasable() -> M.Key? {
        while let key = releasable.first {
            if held[key] == nil, let queue = parked[key], !queue.isEmpty { return key }
            releasable.removeFirst()
        }
        return nil
    }

    @inlinable mutating func popParked(_ key: M.Key) -> Parked<M>? {
        guard let item = parked[key]?.pop() else { return nil }
        parkedCount -= 1
        if parked[key]?.isEmpty == true { parked.removeValue(forKey: key) }
        return item
    }
}
