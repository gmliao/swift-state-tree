// The barrier wait (#953): a caller whose reply is deferred until a step releases its key.

import Foundation

/// A waiting caller handed back to the machine: by `Turn.release(where:)`, or by
/// `TurnMachine.handleWaitEnded` when its wait ended another way.
public struct ReleasedWait<M: TurnMachine>: Sendable {
    public let caller: InputID
    public let key: M.BarrierKey
    /// What the caller held when it waited (`Turn.wait`). Every payload comes back exactly once.
    public let payload: M.BarrierPayload
    /// Whether the caller's `.cancelsCall` task had been cancelled when this was read: at the
    /// `release(where:)` call, once for the whole array, or at the hook's step. Always false for
    /// an `.ignoresCancel` caller, whose cancellation is not observed.
    public let cancelled: Bool

    @inlinable init(caller: InputID, key: M.BarrierKey, payload: M.BarrierPayload, cancelled: Bool) {
        self.caller = caller
        self.key = key
        self.payload = payload
        self.cancelled = cancelled
    }
}

/// How a registered wait ended without a release. Stepped as `handleWaitEnded`, after the step
/// or entry that ended it, before the caller's answer leaves the core.
public enum WaitEnd: Sendable, Equatable {
    /// The caller's `.cancelsCall` cancellation withdrew it; it is answered `CancellationError`
    /// once the hook's step ends. A reply from the hook finds no waiter.
    case withdrawn
    /// Its `timeout` passed. The hook answers it (the default: `TurnError.timedOut`).
    case timedOut
    /// A reply to the caller was published while it waited (`Turn.reply`, also one
    /// `reply(after:)` published): the caller has its answer; the hook only cleans up.
    case answered
    /// `endAll()` ended the core. The hook answers it (the default: `TurnError.closed`).
    case ended

    /// The default hook's answer.
    @inlinable public var error: any Error {
        switch self {
        case .withdrawn: CancellationError()
        case .timedOut: TurnError.timedOut
        case .answered, .ended: TurnError.closed
        }
    }
}

/// Why `Turn.wait` didn't register.
public enum WaitRefusal: Sendable, Equatable {
    /// The caller has no waiter: a pre-cancelled `.control` input, or a caller already answered.
    case noWaiter
    /// The caller's `.cancelsCall` task is cancelled.
    case cancelled
    /// `endAll()` has ended the core.
    case ended
}

/// What `Turn.wait` did. A wait that didn't register hands its payload back here, to the step
/// that tried, which cleans it up and answers the caller.
public enum WaitOutcome<M: TurnMachine>: Sendable {
    /// Registered: the release, the withdraw, the timeout, a published reply or `endAll` ends it,
    /// and the payload comes back through `release(where:)` or `handleWaitEnded`.
    case waiting
    /// Not registered. A cancelled caller that is also expired is `.refused(_, .cancelled)`.
    case refused(M.BarrierPayload, WaitRefusal)
    /// Not registered: the budget was `<= .zero`.
    case expired(M.BarrierPayload)
}

@usableFromInline
struct BarrierEntry<M: TurnMachine> {
    @usableFromInline var key: M.BarrierKey
    @usableFromInline var payload: M.BarrierPayload
    /// The generation of its timeout, when it has one: a fresh one per registration.
    @usableFromInline var timer: UInt64?
    /// Its timeout's heap entry was pushed: only then does its removal leave a stale entry.
    @usableFromInline var armed = false

    @inlinable init(key: M.BarrierKey, payload: M.BarrierPayload, timer: UInt64?) {
        self.key = key
        self.payload = payload
        self.timer = timer
    }
}

/// A reply the driver claimed for a waiting caller, held until `handleWaitEnded(.answered)` ran.
@usableFromInline
struct HeldAnswer<M: TurnMachine> {
    @usableFromInline let waiter: CheckedContinuation<M.Reply, any Error>
    @usableFromInline let result: Result<M.Reply, any Error>

    @inlinable init(waiter: CheckedContinuation<M.Reply, any Error>, result: Result<M.Reply, any Error>) {
        self.waiter = waiter
        self.result = result
    }
}

/// A registered wait that ended without a release, for the driver to step (`handleWaitEnded`).
@usableFromInline
struct WaitEnded<M: TurnMachine> {
    @usableFromInline let caller: InputID
    @usableFromInline let entry: BarrierEntry<M>
    @usableFromInline let why: WaitEnd
    /// `.answered`: the published reply, resumed after the hook's step.
    @usableFromInline let answer: HeldAnswer<M>?

    @inlinable init(caller: InputID, entry: BarrierEntry<M>, why: WaitEnd, answer: HeldAnswer<M>?) {
        self.caller = caller
        self.entry = entry
        self.why = why
        self.answer = answer
    }
}

/// The `.cancelsCall` callers whose task was cancelled, on a core with barriers. Written by the
/// caller's `onCancel` (any thread, synchronously inside `cancel()`) and removed only by the
/// cancellation's hop to the actor (`callerCancelled`), on every one of its exits: so an ID
/// stays set for the rest of the call's life (across a release and a re-wait), and a cancel
/// that lands after the reply is removed by its own hop. Ordinary replies never touch it.
@usableFromInline
final class CancelledCallers: @unchecked Sendable {
    @usableFromInline let lock = NSLock()
    @usableFromInline var ids: Set<InputID> = []

    @inlinable init() {}

    @inlinable func insert(_ id: InputID) {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(id)
    }

    @inlinable func remove(_ id: InputID) {
        lock.lock()
        defer { lock.unlock() }
        ids.remove(id)
    }

    @inlinable func contains(_ id: InputID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }

    /// The ones of `candidates` set now, read under one lock: one snapshot for a whole release.
    @inlinable func cancelled(among candidates: [InputID]) -> Set<InputID> {
        lock.lock()
        defer { lock.unlock() }
        return ids.intersection(candidates)
    }

    /// Tests: how many IDs are set now.
    @inlinable var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ids.count
    }
}

extension Runtime {
    /// Takes `caller`'s entry out of the table, its timer invalidated. `fired`: its timeout's heap
    /// entry is the one firing, already out of the heap.
    @inlinable mutating func removeBarrier(_ caller: InputID, fired: Bool = false) -> BarrierEntry<M>? {
        guard let entry = barrierWaiters.removeValue(forKey: caller) else { return nil }
        if let count = barrierCounts[entry.key], count > 1 {
            barrierCounts[entry.key] = count - 1
        } else {
            barrierCounts.removeValue(forKey: entry.key)
        }
        if let timer = entry.timer, barrierTimers.removeValue(forKey: timer) != nil, entry.armed, !fired {
            // Its heap entry is stale now. A staged, unarmed one is filtered out at its arm.
            staleDeadlines &+= 1
        }
        return entry
    }
}

extension Turn {
    /// Defers `caller`'s reply: it waits on `key`, holding `payload`, until a step releases the
    /// key (`release(where:)`), `timeout` passes, its `.cancelsCall` cancellation withdraws it, a
    /// reply to it is published, or `endAll()` ends the core. Every exit but the release steps
    /// `handleWaitEnded` with the payload, in a step of its own.
    ///
    /// `timeout` is a budget from `now` (the batch's clock sample), saturating; it makes the
    /// timeout eligible at that instant, not exact: a release the driver serves first still wins.
    ///
    /// Stops the process (debug and release alike) when `caller` already waits, or has a reply
    /// staged (`reply`, also one held for a request by `reply(after:)`): one caller, one answer.
    /// A replaying core refuses it too: the cancellation flag can't be replayed.
    @inlinable
    public mutating func wait(
        _ caller: InputID, on key: M.BarrierKey, holding payload: M.BarrierPayload, timeout: Duration? = nil
    ) -> WaitOutcome<M> {
        if TurnCore<M>.usesMailbox, core.mailReplay != nil {
            fatalError("TurnCore: a replaying core doesn't take barrier waits")
        }
        if core.rt.barrierWaiters[caller] != nil {
            fatalError("TurnCore: a caller waits on a barrier once at a time")
        }
        if core.rt.replies.contains(where: { $0.0 == caller })
            || core.rt.repliesAfter.values.contains(where: { $0.contains { $0.0 == caller } }) {
            fatalError("TurnCore: a caller with a staged reply can't wait")
        }
        if core.rt.ended { return .refused(payload, .ended) }
        guard core.waiters[caller] != nil else { return .refused(payload, .noWaiter) }
        if core.isCancelled(caller) { return .refused(payload, .cancelled) }
        var timer: UInt64?
        if let timeout {
            if timeout <= .zero { return .expired(payload) }
            let instant = TurnCore<M>.saturatingDeadline(core.segmentNow().nanoseconds, timeout)
            core.rt.nextBarrierTimer &+= 1
            let generation = core.rt.nextBarrierTimer
            timer = generation
            core.rt.barrierTimers[generation] = caller
            core.rt.barrierTimersToArm.append((generation, TurnInstant(nanoseconds: instant)))
            core.rt.dirty = true
        }
        core.rt.barrierWaiters[caller] = BarrierEntry(key: key, payload: payload, timer: timer)
        core.rt.barrierCounts[key, default: 0] += 1
        core.counters.barrierWaits += 1
        core.onDiagnostic?(.barrierWait)
        return .waiting
    }

    /// Takes every caller waiting on a key that `matches` out of the table, oldest first by
    /// `InputID` across the matching keys, each with its timer invalidated and its `cancelled`
    /// read now, once for the whole array. The machine replies to each one, or continues it
    /// with `&turn` (which may `wait` it again), in this step.
    @inlinable
    public mutating func release(where matches: (M.BarrierKey) -> Bool) -> [ReleasedWait<M>] {
        if core.rt.barrierWaiters.isEmpty { return [] }
        let ids = core.rt.barrierWaiters.filter { matches($0.value.key) }.keys.sorted { $0.raw < $1.raw }
        let cancelled = core.cancelledCallers?.cancelled(among: ids) ?? []
        var released: [ReleasedWait<M>] = []
        released.reserveCapacity(ids.count)
        for id in ids {
            guard let entry = core.rt.removeBarrier(id) else { continue }
            released.append(ReleasedWait(caller: id, key: entry.key, payload: entry.payload,
                                     cancelled: cancelled.contains(id)))
        }
        return released
    }

    /// The callers waiting on `key` now.
    @inlinable public func waiterCount(on key: M.BarrierKey) -> Int {
        core.rt.barrierCounts[key] ?? 0
    }
}

extension MailTurn {
    /// `Turn.release(where:)`: a mail can finish a waiting caller. It can't make one wait (a mail
    /// has no caller); a continuation that must wait again hands off through an input.
    @inlinable
    public mutating func release(where matches: (M.BarrierKey) -> Bool) -> [ReleasedWait<M>] {
        turn.release(where: matches)
    }

    /// `Turn.waiterCount(on:)`.
    @inlinable public func waiterCount(on key: M.BarrierKey) -> Int { turn.waiterCount(on: key) }
}

extension TurnCore {
    /// The machine has barriers (`BarrierKey` isn't `Never`). A constant once specialized: the
    /// barrier paths fold away for a machine without them.
    @inlinable static var usesBarriers: Bool { M.BarrierKey.self != Never.self }

    /// A registered wait that ended without a release, in a step of its own.
    @inlinable func stepWaitEnded(_ caller: InputID, _ entry: BarrierEntry<M>, _ why: WaitEnd) {
        noteDispatch()
        enterStep(nil)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        let released = ReleasedWait<M>(caller: caller, key: entry.key, payload: entry.payload,
                                   cancelled: isCancelled(caller))
        machine.handleWaitEnded(released, why, &turn)
    }

    /// `now + budget` for a positive budget, clamped at `Int64.max` as an instant (not as a
    /// budget first: a budget past `Int64`'s range still lands below it from a negative `now`).
    @inlinable package static func saturatingDeadline(_ now: Int64, _ budget: Duration) -> Int64 {
        let widest = Duration.nanoseconds(Int64.max)
        if budget <= widest {
            let (sum, overflow) = now.addingReportingOverflow(budget.turnNanoseconds)
            return overflow ? .max : sum
        }
        if now >= 0 { return .max }
        let (sum, overflow) = (now &+ Int64.max).addingReportingOverflow((budget - widest).turnNanoseconds)
        return overflow ? .max : sum
    }

    /// Whether `caller`'s `.cancelsCall` task has been cancelled (barrier cores only).
    @inlinable func isCancelled(_ caller: InputID) -> Bool {
        cancelledCallers?.contains(caller) == true
    }

    /// Tests: the barrier waiters now, and the cancellation flags set now.
    package var barrierWaitersForTesting: Int { rt.barrierWaiters.count }
    package var cancelledCallersForTesting: Int { cancelledCallers?.count ?? 0 }
    /// Tests: the instant the core's timer sleeps until, if it sleeps.
    package var sleeperTargetForTesting: TurnInstant? { sleeperTarget }
}
