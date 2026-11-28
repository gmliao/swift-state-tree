// The core's own state: lifetimes, requests, holds, queued inputs and what a step leaves for the
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
    /// It was made with a deadline: an entry for it is (or is about to be) in the core's deadline
    /// heap.
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
    @usableFromInline var token: WithdrawToken?
    /// Queued by a step (`Turn.queue`): `close`, scopes and the queue limit don't apply.
    @usableFromInline var pinned: Bool

    @inlinable init(input: M.Input, caller: InputID?, scope: M.Key?, token: WithdrawToken?, pinned: Bool = false) {
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

/// A timer for the driver to arm on the core's timer. Its input stays in `Runtime.timers`.
@usableFromInline
struct PendingTimer<M: TurnMachine> {
    @usableFromInline var key: M.Key
    @usableFromInline var generation: UInt64
    @usableFromInline var instant: TurnInstant

    @inlinable init(key: M.Key, generation: UInt64, instant: TurnInstant) {
        self.key = key
        self.generation = generation
        self.instant = instant
    }
}

/// A key's current timer: its generation and the input it steps.
@usableFromInline
struct ArmedTimer<M: TurnMachine> {
    @usableFromInline var generation: UInt64
    @usableFromInline var input: M.Input

    @inlinable init(generation: UInt64, input: M.Input) {
        self.generation = generation
        self.input = input
    }
}

/// A follow-up's name: its owner key and its slot.
@usableFromInline
struct FollowUpKey<M: TurnMachine>: Hashable {
    @usableFromInline var key: M.Key
    @usableFromInline var slot: M.FollowUpSlot

    @inlinable init(key: M.Key, slot: M.FollowUpSlot) {
        self.key = key
        self.slot = slot
    }
}

/// A pending follow-up: its id and the input it steps.
@usableFromInline
struct FollowUpRecord<M: TurnMachine> {
    @usableFromInline var id: RequestID
    @usableFromInline var input: M.Input
    /// Its gate (`.afterWork`) hasn't returned yet; false once it is due to step.
    @usableFromInline var waiting: Bool
    /// A deadline entry was armed on the core's timer for its gate.
    @usableFromInline var hasDeadline: Bool

    @inlinable init(id: RequestID, input: M.Input, waiting: Bool, hasDeadline: Bool) {
        self.id = id
        self.input = input
        self.waiting = waiting
        self.hasDeadline = hasDeadline
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
    /// Closed requests whose worker still keeps a hold (`Hold.untilWorkerReturns`).
    @usableFromInline var retiring: [RequestID: M.Key] = [:]
    /// Hold key → how many open requests (or workers that have not returned) own it.
    @usableFromInline var held: [M.Key: Int] = [:]
    /// Deadline heap entries invalidated (their request or gate closed, their timer replaced or
    /// dropped) and not yet removed. Approximate
    /// (a request closed in the step that made it was never inserted): it only decides when the heap
    /// is compacted (`TurnCore.compactDeadlinesIfStale`).
    @usableFromInline var staleDeadlines = 0
    // Timers: the current one per key, by generation, with its input. A replaced or dropped
    // timer's input is released here at once; its heap entry, plain data, stays stale.
    @usableFromInline var nextTimer: UInt64 = 0
    @usableFromInline var timers: [M.Key: ArmedTimer<M>] = [:]
    /// The current timers' generations, to their keys: a heap entry's ticket finds its timer.
    @usableFromInline var timerKeys: [UInt64: M.Key] = [:]
    @usableFromInline var timersToArm: [PendingTimer<M>] = []
    // Queued normal inputs, by hold key.
    @usableFromInline var parked: [M.Key: FIFO<Parked<M>>] = [:]
    @usableFromInline var parkedCount = 0
    /// Inputs queued so far (for the diagnostics hook).
    @usableFromInline var parkEvents = 0
    /// Hold keys released while inputs were queued behind them.
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
    /// Queued `send`s (no caller) withdrawn or dropped by `close`; `TurnStats.droppedSends`.
    @usableFromInline var droppedParkedSends = 0
    /// Set by `endAll`: the core is terminal, and no key can be started again.
    @usableFromInline var ended = false
    /// `start`, `queue` and `followUp` calls made after the end, and ignored.
    @usableFromInline var ignoredAfterEnd = 0
    // Follow-ups: one pending per key and slot, owned by the key's generation.
    @usableFromInline var followUps: [FollowUpKey<M>: FollowUpRecord<M>] = [:]
    @usableFromInline var followUpIDs: [RequestID: FollowUpKey<M>] = [:]
    /// `.afterBatch` follow-ups armed since the last continuation job took them, in arm order (a closed or
    /// consumed one is skipped when it comes up).
    @usableFromInline var dueFollowUps: [RequestID] = []
    /// Gates (`.afterWork`) for the driver to launch.
    @usableFromInline var followUpGates: [PendingEffect<M>] = []
    // Barrier waits (#953): the waiting callers, by caller, and how many wait on each key.
    @usableFromInline var barrierWaiters: [InputID: BarrierEntry<M>] = [:]
    @usableFromInline var barrierCounts: [M.BarrierKey: Int] = [:]
    /// The live barrier timeouts' generations, to their callers: a heap entry of kind `.barrier`
    /// is live while its generation is here. Fresh per registration, so a re-wait gets a new one.
    @usableFromInline var nextBarrierTimer: UInt64 = 0
    @usableFromInline var barrierTimers: [UInt64: InputID] = [:]
    @usableFromInline var barrierTimersToArm: [(UInt64, TurnInstant)] = []
    /// Registered waits that ended without a release (a published reply, `endAll`), for the
    /// driver to step through `handleWaitEnded`, in order.
    @usableFromInline var waitsEnded = FIFO<WaitEnded<M>>()
    /// Callers whose wait ended and whose hook hasn't stepped (`Settling`).
    @usableFromInline var settling: [InputID: Settling<M>] = [:]
    /// Answers fixed for callers whose hook has stepped, published in the drain's replies phase
    /// after the outputs; `releasing` drops the hook's own reply to them meanwhile.
    @usableFromInline var released: [(InputID, Result<M.Reply, any Error>)] = []
    @usableFromInline var releasing: Set<InputID> = []
    /// Set by `endAll` while waits remain: the driver ends them after publishing the step's replies.
    @usableFromInline var endingWaits = false

    @inlinable init() {}

    /// Removes a pending follow-up without stepping it, and returns it.
    @inlinable mutating func removeFollowUp(_ id: RequestID) -> FollowUpRecord<M>? {
        guard let name = followUpIDs.removeValue(forKey: id), let record = followUps.removeValue(forKey: name) else { return nil }
        if record.hasDeadline { staleDeadlines &+= 1 }
        dirty = true
        return record
    }

    /// Closes a pending follow-up unrun: `handleAbandoned` steps for it in this batch.
    @inlinable mutating func closeFollowUp(_ id: RequestID, _ why: Abandonment) {
        guard removeFollowUp(id) != nil else { return }
        abandoned.append((id, why))
    }

    /// Closes every follow-up of `key` (all of them when nil), in arm order.
    @inlinable mutating func closeFollowUps(of key: M.Key?) {
        if followUps.isEmpty { return }
        let ids = followUpIDs.filter { key == nil || $0.value.key == key }.map(\.key).sorted { $0.raw < $1.raw }
        for id in ids { closeFollowUp(id, .keyEnded) }
    }

    /// A follow-up whose gate hasn't returned, with a deadline: its deadline entry is live.
    @inlinable func gateDeadlineLive(_ id: RequestID) -> Bool {
        guard let name = followUpIDs[id], let record = followUps[name] else { return false }
        return record.waiting && record.hasDeadline
    }

    /// Pending work of `kinds`, of `key` (all keys when nil).
    @inlinable func pendingCount(_ kinds: TurnWork, of key: M.Key?) -> Int {
        var count = 0
        if kinds.contains(.followUps) {
            count += key.map { k in followUpIDs.values.filter { $0.key == k }.count } ?? followUps.count
        }
        if kinds.contains(.requests) {
            count += key.map { k in open.values.filter { $0.key == k }.count } ?? open.count
        }
        if kinds.contains(.timers) {
            count += key.map { timers[$0] == nil ? 0 : 1 } ?? timers.count
        }
        return count
    }

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
        if record.hasDeadline { staleDeadlines &+= 1 }
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
        if let old = timers.removeValue(forKey: key) {
            timerKeys.removeValue(forKey: old.generation)
            staleDeadlines &+= 1
            dirty = true
        }
    }

    /// The worker of a closed request returned: a hold it kept is released.
    @inlinable mutating func retire(_ id: RequestID) {
        if let hold = retiring.removeValue(forKey: id) { releaseHold(hold) }
    }

    /// Removes the queued inputs `predicate` picks. Their callers are answered `withdrawn`,
    /// sorted by call so a run repeats; the order callers observe is unspecified.
    @inlinable mutating func withdraw(where predicate: (Parked<M>) -> Bool) {
        if parkedCount == 0 { return }
        var callers: [InputID] = []
        for key in Array(parked.keys) {
            guard var queue = parked[key] else { continue }
            let removed = queue.remove(where: predicate)
            if removed.isEmpty { continue }
            parkedCount -= removed.count
            for item in removed {
                if let caller = item.caller {
                    callers.append(caller)
                } else if !item.pinned {
                    droppedParkedSends += 1
                }
            }
            parked[key] = queue.isEmpty ? nil : queue
            dirty = true
        }
        withdrawn.append(contentsOf: callers.sorted { $0.raw < $1.raw })
    }

    /// Removes a cancelled caller's queued input, if it is still queued.
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

    /// Drops every queued normal input (`close`) and returns their callers. What a step
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
                } else {
                    droppedParkedSends += 1
                }
            }
            if !keep.isEmpty { kept[key] = keep }
        }
        parked = kept
        parkedCount = keptCount
        releasable.removeAll { kept[$0] == nil }
        // In call order, not the hash order of the hold keys.
        return callers.sorted { $0.raw < $1.raw }
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

    /// The next key whose queued inputs may step: released, not held again, not empty.
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
