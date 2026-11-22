// The machine, the runtime and the step.

/// The core's counters, read between steps.
public struct TurnStats: Sendable, Equatable {
    /// Normal inputs queued now.
    public var queued = 0
    public var openRequests = 0
    public var heldKeys = 0
    public var liveKeys = 0
    /// `sendAndWait`s waiting for their reply.
    public var pendingWaiters = 0
    /// `emit`s under a key that wasn't live.
    public var droppedOutputs = 0
    /// `start`, `queue` and `followUp` calls after `endAll`.
    public var ignoredAfterEnd = 0
    /// `send`s refused (closed, withdrawn or over the queue limit), or queued and then withdrawn
    /// or closed (`end`, a supersede, `revoke`, `close`, `endAll`), which had no caller to answer.
    public var droppedSends = 0
    /// Completions and deadlines from another core (a replaced one), dropped.
    public var foreignCompletions = 0
    /// Continuation jobs scheduled: by a batch whose released inputs were left for a later batch
    /// by the budget, by one that left `.afterBatch` follow-ups due, or by one that did both.
    /// At most one is pending at a time.
    public var continuationJobs = 0
    /// Calls answered with `CancellationError` under `.cancelsCall`.
    public var cancelledCalls = 0
    /// Follow-ups armed and not yet stepped, consumed or closed.
    public var pendingFollowUps = 0

    @inlinable public init() {}
}

/// What a test may wait for, reported synchronously on the actor where it happens.
public enum TurnDiagnostic: Sendable, Equatable {
    case queued(total: Int)
    case batchEnded(released: Int)
    case foreignCompletion
    /// The core's timer reached the deadline of a request or a follow-up gate that had already
    /// closed, and did nothing. It comes at the deadline's instant, or never: a closed entry that
    /// the core drops first (it compacts its deadlines, or `endAll` empties them) reports nothing.
    case staleDeadline
    /// The core's timer reached a timer that had been replaced or dropped, and did nothing. It
    /// comes at the timer's instant, or never: an entry the core drops first (it compacts its
    /// deadlines, or `endAll` empties them) reports nothing.
    case staleTimer
    /// A follow-up's gate returned after the follow-up was consumed or closed, and stepped
    /// nothing for it.
    case staleFollowUp
    case clockRead
}

/// A `waitForQuiescence` caller.
@usableFromInline
struct QuiescenceWaiter<M: TurnMachine> {
    @usableFromInline var kinds: TurnWork
    @usableFromInline var key: M.Key?
    @usableFromInline var atMost: Int
    @usableFromInline var continuation: CheckedContinuation<Bool, Never>

    @inlinable init(kinds: TurnWork, key: M.Key?, atMost: Int, continuation: CheckedContinuation<Bool, Never>) {
        self.kinds = kinds
        self.key = key
        self.atMost = atMost
        self.continuation = continuation
    }
}

/// The machine, the runtime and the step. Not `Sendable`: only its actor reaches it, through
/// a stored `let`.
public final class TurnCore<M: TurnMachine> {
    /// The machine names follow-up slots. A constant once the core is specialized for a
    /// machine, so the driver's follow-up paths fold away for one that keeps the default
    /// (`Never`) and it pays nothing per segment for them.
    @inlinable static var usesFollowUps: Bool { M.FollowUpSlot.self != Never.self }

    // Release builds skip the runtime exclusivity checks on the core's own state (#621): with
    // the core inlined into its adopter, each use of a stored var otherwise pays a
    // `swift_beginAccess`/`swift_endAccess` pair. The actor serializes every access, and the core
    // stops the process on the overlaps a check would catch, by the borrow rule of `borrows`
    // (a step inside a step or inside a read, nested or not; a read or a query inside a step).
    // It can't stop adopter code that the core runs
    // during its own accesses: `M.Key`'s `==` and `hash(into:)` (run inside mutations of `rt`,
    // `deadlines` (a compaction's liveness check) and `scopeEndsWhileDeferred`) and the deinits of
    // inputs and keys the core drops (`queued`, a withdraw, `removeAll`). Those must not call back into the actor; an
    // adopter tests that with the checked build. Debug builds keep the checks, and so does a
    // release build with `-Xswiftc -DTURNS_EXCLUSIVITY_CHECKED`. Every stored var carries the
    // attribute under this exact condition (scripts/lint-turns.sh, rule unchecked-state).
    /// Changed only inside a step.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var machine: M
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var rt = Runtime<M>()
    /// The machine's borrow state, kept as Rust's `RefCell` keeps its flag: 0 unused, n > 0 that
    /// many `read`s open, -1 a step writing. The rule is SE-0176's: reads nest, a read and a write
    /// or two writes don't.
    ///
    /// | state     | `read`  | a step (`send` stepping now, `sendAndWait`, `query`) |
    /// |-----------|---------|------------------------------------------------------|
    /// | 0         | → 1     | → -1                                                 |
    /// | n > 0     | → n + 1 | stop                                                 |
    /// | -1        | stop    | stop (`query`)                                       |
    ///
    /// A read gives back n - 1 and a step gives back 0, on every exit (`defer`). A `send` made
    /// while writing isn't a step entry: `submit` defers it, and it steps after the step ends.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var borrows = 0
    /// Tests: the borrow state between calls (0 when nothing is open).
    package var borrowStateForTesting: Int { borrows }
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var inSegment = false
    /// Sends and calls made while a step or a batch was running, each with the scope-end clock
    /// at its arrival.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var queued = FIFO<(M.Input, InputID?, UInt64)>()
    /// While inputs are deferred (`queued`), the clock reading at each key's latest end or
    /// supersede, keyed by the ended key (not by the deferred inputs' scopes). A deferred input
    /// whose scope ended after it arrived is withdrawn when it is admitted. Emptied when `queued`
    /// drains, so its size is bounded by one batch's ends.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var scopeEndsWhileDeferred: [M.Key: UInt64] = [:]
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var scopeEndClock: UInt64 = 0
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var waiters: [InputID: CheckedContinuation<M.Reply, any Error>] = [:]
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var nextInput: UInt64 = 0
    /// A continuation job (`continueBatch`) is scheduled: one for the drain's capped releases
    /// and the due `.afterBatch` follow-ups both.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var continuationScheduled = false
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var counters = TurnStats()
    /// The batch's clock reading, taken on first use.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var cachedNow: TurnInstant?
    /// Every armed request deadline, gate deadline and timer, by (instant, arm order) (#621 item 2,
    /// Notes/plans/2026-11-21-turns-shared-deadline-timer.md). Lazy deletion: a closed one stays
    /// until a wake reaches it or a compaction drops it (`rt.staleDeadlines`).
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var deadlines = DeadlineHeap()
    /// The arm counter: entries at one instant fire in arm order.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var nextArm: UInt64 = 0
    /// The one sleeping task of the core's timer, until `sleeperTarget`; nil when nothing is armed.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var sleeper: Task<Void, Never>?
    /// Bumped at each sleeper start, and when `endAll` stops the timer: a wake from an older
    /// sleeper is superseded.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var sleeperGeneration: UInt64 = 0
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var sleeperTarget: TurnInstant?
    /// A wake is being serviced on the actor: an arm doesn't re-arm, the wake's return gives the
    /// next target.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var sleeperAwake = false
    /// Tests: sleeper tasks started.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var sleeperStartsForTesting = 0
    /// Tests: wakes dropped as superseded (a re-armed, stopped or deinit-cancelled sleeper's).
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var supersededWakesForTesting = 0
    /// Tests: wakes serviced (not foreign, not superseded).
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var timerWakesForTesting = 0
    /// Tests: called on the actor at each wake of the core's timer that isn't foreign, with
    /// whether it was superseded, before it steps anything. Observe-only, as
    /// `onContinuationJobForTesting`; one nil check per wake.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onTimerWakeForTesting: ((_ superseded: Bool) -> Void)?
    /// Tests: entries in the deadline heap that are still live.
    package var liveDeadlinesForTesting: Int { deadlines.storage.reduce(0) { $0 + (deadlineIsLive($1) ? 1 : 0) } }
    /// Tests: the timer inputs the core holds, one per current timer: a replaced or dropped
    /// timer's input is released at once, while its heap entry is still there.
    package var liveTimerInputsForTesting: Int { rt.timers.count }
    /// Tests: entries in the deadline heap, stale ones included.
    package var deadlineEntriesForTesting: Int { deadlines.count }
    /// Tests: how many follow-up gates the core has launched; counted in debug builds only.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var gateLaunchesForTesting = 0
    /// Follow-ups taken by the current continuation job at its start, to step in this batch.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var followUpsToStep = FIFO<RequestID>()
    /// `waitForQuiescence` callers, by id: each returns once at most `atMost` of its kinds are
    /// pending.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var quiescenceWaiters: [UInt64: QuiescenceWaiter<M>] = [:]
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var nextQuiescenceWaiter: UInt64 = 0
    /// Tests: how many quiescence waiters are registered.
    package var quiescenceWaitersForTesting: Int { quiescenceWaiters.count }
    /// Tests: called where a quiescence wait registers, after its re-check and before the entry,
    /// so a test can see on which executor that runs.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onQuiescenceRegistrationForTesting: (() -> Void)?
    /// Tests: called once at the start of each continuation job, before it takes the due
    /// follow-ups, in every build configuration; a test sees the job boundaries with it.
    /// It runs on the actor, between steps, after the job's flag clears and before the job takes
    /// the due follow-ups. Observe-only: a hook that called `send` or `query` would run a nested
    /// segment there, ahead of the capture. It costs one nil check per job, not per segment.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onContinuationJobForTesting: (() -> Void)?
    // Debug builds fill these (`effectsByInput`). Stored in every build, because inlined code
    // in a client compiled in another configuration may name them.
    /// The case name of the input stepping now.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var stepCase: String?
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var effectCounts: [String: Int] = [:]
    /// Test-only: called on the actor, synchronously, where the event happens. Package access:
    /// the adopters that set it are in this package.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onDiagnostic: ((TurnDiagnostic) -> Void)?
    /// Tells this core's completions from another core's (a replaced core).
    @usableFromInline let incarnation: UInt64
    @usableFromInline let queueLimit: Int
    @usableFromInline let maxReleasesPerBatch: Int
    @usableFromInline let clock: any TurnClock

    /// - Parameters:
    ///   - machine: the machine in its initial state.
    ///   - queueLimit: how many normal inputs may be queued at once.
    ///   - maxReleasesPerBatch: how many queued inputs a hold's release lets step per batch;
    ///     abandonments and sends that arrive during the batch don't count.
    ///   - clock: what `Turn.now`, deadlines and timers read and sleep on.
    ///
    /// Only a `PlainData` machine can be run: `@PlainData` writes that conformance and checks
    /// every stored field, so a machine that stores a class or a closure doesn't compile here.
    public init(_ machine: M, queueLimit: Int, maxReleasesPerBatch: Int, clock: some TurnClock) where M: PlainData {
        // `fatalError`, not `precondition`: its message prints in release builds too.
        if M.self is AnyClass { fatalError("TurnCore: the machine must be a value type, not \(M.self)") }
        if queueLimit < 0 { fatalError("TurnCore: queueLimit must not be negative") }
        if maxReleasesPerBatch < 1 { fatalError("TurnCore: maxReleasesPerBatch must be at least 1") }
        self.machine = machine
        self.queueLimit = queueLimit
        self.maxReleasesPerBatch = maxReleasesPerBatch
        self.clock = clock
        self.incarnation = UInt64.random(in: UInt64.min ... UInt64.max)
    }

    deinit {
        assert(waiters.isEmpty, "TurnCore: a caller was never answered")
        sleeper?.cancel()
    }

    // MARK: The deadline heap

    /// At most this many due entries step per wake; the rest steps after other queued entries,
    /// on the next wake (§3.6 of the plan). Separate from `maxReleasesPerBatch`.
    @inlinable static var maxFiresPerWake: Int { 64 }
    /// A compaction needs at least this many stale entries, and at least half the heap stale.
    @inlinable static var compactionFloor: Int { 64 }

    /// Whether `entry`'s request is open, its follow-up's gate deadline still pending, or its
    /// timer still its key's current one.
    @inlinable func deadlineIsLive(_ entry: DeadlineEntry) -> Bool {
        if entry.isTimer { return rt.timerKeys[entry.ticket] != nil }
        let id = RequestID(raw: entry.ticket)
        if rt.open[id] != nil { return true }
        return Self.usesFollowUps && rt.gateDeadlineLive(id)
    }

    /// Drops the stale entries in O(n) once they are at least `compactionFloor` and half the heap,
    /// so the heap holds at most `max(compactionFloor, 2 × live) + 1` entries, at amortized O(1)
    /// per invalidation. The sleeper isn't re-armed: a removed target costs one wake that steps
    /// nothing.
    @inlinable func compactDeadlinesIfStale() {
        let stale = rt.staleDeadlines
        guard stale >= Self.compactionFloor, stale &* 2 >= deadlines.count else { return }
        deadlines.rebuild { deadlineIsLive($0) }
        rt.staleDeadlines = 0
    }

    /// `endAll`'s stop: no entry can be live again, so the heap empties and the sleeper is
    /// cancelled and superseded. Synchronous and terminal; reads no machine state.
    @inlinable func stopDeadlines() {
        deadlines.removeAll()
        rt.staleDeadlines = 0
        sleeper?.cancel()
        sleeper = nil
        sleeperTarget = nil
        sleeperGeneration &+= 1
    }

    /// Reads the machine. Between steps only: from inside a step it stops the process. Reads
    /// nest; a step entered from a read's body (a `send`, a `query`) stops the process.
    @inlinable public func read<R>(_ body: (borrowing M) -> R) -> R {
        if borrows < 0 { fatalError("TurnCore: the machine was read from inside its own step") }
        borrows += 1
        defer { borrows -= 1 }
        return body(machine)
    }

    public var stats: TurnStats {
        var stats = counters
        stats.queued = rt.parkedCount
        stats.openRequests = rt.open.count
        stats.heldKeys = rt.held.count
        stats.liveKeys = rt.live.count
        stats.pendingWaiters = waiters.count
        stats.droppedOutputs = rt.droppedOutputs
        stats.droppedSends += rt.droppedParkedSends
        stats.ignoredAfterEnd = rt.ignoredAfterEnd
        stats.pendingFollowUps = rt.followUps.count
        return stats
    }

    /// Debug builds: how many effects (`request`, `run`, and a follow-up's `.afterWork` gate) each
    /// input case started, by the case's name, so an adopter's tests can assert zero for its hot
    /// inputs. A gate counts when its arm stages it, also if launch then filters it out. Empty in
    /// release.
    public var effectsByInput: [String: Int] {
        effectCounts
    }

    // MARK: The clock

    @inlinable func segmentNow() -> TurnInstant {
        if let cachedNow { return cachedNow }
        let now = clock.now
        cachedNow = now
        onDiagnostic?(.clockRead)
        return now
    }

    @inlinable func noteEffect() {
        #if DEBUG
        effectCounts[stepCase ?? "(none)", default: 0] += 1
        #endif
    }

    // MARK: Steps

    @inlinable func enterStep(_ input: M.Input?) {
        if borrows < 0 { fatalError("TurnCore: a step was entered from inside a step") }
        if borrows > 0 { fatalError("TurnCore: a step was entered while a read is open") }
        borrows = -1
        #if DEBUG
        stepCase = input.map(Self.caseName)
        #endif
    }

    @inlinable func leaveStep() {
        borrows = 0
        #if DEBUG
        stepCase = nil
        #endif
    }

    @usableFromInline static func caseName(_ input: M.Input) -> String {
        let text = String(describing: input)
        if let paren = text.firstIndex(of: "(") { return String(text[..<paren]) }
        return text
    }

    /// `key`'s binding ended (`end`) or was superseded (`start` over a live key): the deferred
    /// inputs that arrived before now and belong to it are withdrawn when they are admitted.
    @inlinable func scopeEnded(_ key: M.Key) {
        if queued.isEmpty { return }
        scopeEndClock &+= 1
        scopeEndsWhileDeferred[key] = scopeEndClock
    }

    @inlinable func step(_ input: M.Input, caller: InputID?) {
        enterStep(input)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: caller)
        machine.handle(input, &turn)
    }

    @inlinable func stepStale(_ input: M.Input) {
        enterStep(input)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        machine.handleLateResult(input, &turn)
    }

    @inlinable func stepAbandoned(_ id: RequestID, _ why: Abandonment) {
        enterStep(nil)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        machine.handleAbandoned(id, why, &turn)
    }

    @inlinable func stepAnswer(_ query: M.Query) -> M.Answer {
        if borrows < 0 { fatalError("TurnCore: query was called from inside a step") }
        enterStep(nil)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        return machine.answer(query, &turn)
    }
}
