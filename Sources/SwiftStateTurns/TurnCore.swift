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
    /// Barrier waits registered (`Turn.wait` returning `.waiting`), counted once each.
    public var barrierWaits = 0
    /// Follow-ups armed and not yet stepped, consumed or closed.
    public var pendingFollowUps = 0
    /// Mailbox wakes that found the mailbox empty: an entry took the mail first.
    public var emptyMailboxWakes = 0
    /// Posts refused because the mailbox was full (the first pending mail wins).
    public var refusedMail = 0

    @inlinable public init() {}
}

/// What a test may wait for, reported synchronously on the actor where it happens.
public enum TurnDiagnostic: Sendable, Equatable {
    case queued(total: Int)
    case batchEnded(released: Int)
    case foreignCompletion
    /// The core's timer reached the deadline of a request or a follow-up gate that had already
    /// closed, and did nothing. It comes at the deadline's instant or later, or never: a closed
    /// entry that the core drops first reports nothing. The core drops one when it compacts its
    /// deadlines, when `endAll` empties them, or when a wake clears closed entries due after the
    /// instant it woke for.
    case staleDeadline
    /// The core's timer reached a timer that had been replaced or dropped, or a barrier wait's
    /// timeout whose wait had already ended, and did nothing. It comes at the timer's instant or
    /// later, or never, as `staleDeadline` does.
    case staleTimer
    /// A follow-up's gate returned after the follow-up was consumed or closed, and stepped
    /// nothing for it.
    case staleFollowUp
    /// A call's cancellation found no waiter (the call was answered or refused first, or never
    /// waited), and did nothing.
    case staleCancellation
    /// With a mailbox: a completion with no result whose request was already closed with no
    /// hold to retire, or that had no request (a `run`), arrived and did nothing.
    case idleCompletion
    case clockRead
    /// A barrier wait registered (`Turn.wait` returned `.waiting`).
    case barrierWait
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
    /// The machine takes mail. A constant once specialized, as `usesFollowUps`: every
    /// mailbox path folds away for a machine that keeps the default (`Never`).
    @inlinable static var usesMailbox: Bool { M.Mail.self != Never.self }

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
    /// The machine's behavior (`TurnMachine.Behavior`), fixed at init: steps read it, nothing
    /// writes it.
    @usableFromInline let behavior: M.Behavior
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
    /// Whether a step is writing the machine now (the borrow state is -1): a `send` stepping
    /// now, `sendAndWait`, `query`, a timer, a completion, an abandonment or mail. False between
    /// steps, inside a `read`, and in `flush`. An adopter's synchronous entry reads it on the
    /// shared executor to refuse a call made from inside a step before it reaches the core,
    /// whose own stop for that call ends the process (#700 K2, plan draft 7 §4.2).
    package var isStepping: Bool { borrows < 0 }
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
    /// The worker of each open tracked request (`request`), by its ID: abandoning the request
    /// cancels it, once (structured cancellation: the work a key owns ends with the key). A
    /// handle leaves when its worker returns or its request is abandoned. `run`'s untracked
    /// workers and follow-up gates have none.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var workers: [RequestID: Task<Void, Never>] = [:]
    /// Tests: how many tracked workers have a handle now.
    package var workersForTesting: Int { workers.count }
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
    /// How much more mail this entry may step: `mailbox.capacity` at each entry, spent by
    /// the entry's mailbox take and by every check in its segment.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var mailBudget = 0
    /// Set while an epilogue's remainder wake is scheduled and hasn't started, so a flood of
    /// entries that spend their budget schedules one (a post's own wake isn't coalesced).
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var mailboxWakeScheduled = false
    /// Tests: called on the actor at each mailbox check, after it reads its watermark and before
    /// its first removal, so a test can post there. Observe-only, apart from `post`.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onMailboxCheckForTesting: (() -> Void)?
    /// Tests: called on the actor at the start of each mailbox wake (`mailboxWoke`), before its mailbox
    /// take; a test sees the wake boundaries with it. Observe-only.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onMailboxWakeForTesting: (() -> Void)?
    /// Tests: called on the actor when the epilogue schedules a remainder wake (for mail a spent
    /// budget left), so a test counts it as it is scheduled. The closure it returns is awaited at
    /// the start of that wake's task, before it hops onto the actor, so a test can hold the wake.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onRemainderWakeForTesting: (() -> @Sendable () async -> Void)?
    /// Tests: called on the actor at an entry's boundary (`entryBoundary`), after its mailbox take
    /// and ordinal and before its own work, so a test can post there: a completion, a deadline, a
    /// timer, a gate's return, a cancellation and a withdrawn release's refusal (none for a stale
    /// arrival, which takes no ordinal). Observe-only, apart from `post`.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onEntryBoundaryForTesting: (() -> Void)?
    /// Tests: called on the actor right before a published reply resumes its caller (the
    /// drain's replies phase, a barrier caller's released answer, a plain withdraw), so a check
    /// sees the order of resumes against flushes and steps from inside the segment. Observe-only.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onResumeForTesting: ((InputID) -> Void)?
    /// The next boundary's ordinal, counted over every step the core dispatches (inputs,
    /// releases, follow-ups, answers, completions, timers, abandonments) and every entry's own
    /// work (an admission, a completion, a deadline, a timer, a gate's return; plan §3.9); a mailbox
    /// record's keys name steps by it. An admitted input that steps takes two: its admission and
    /// its dispatch, on both sides alike. Counted only for a machine that takes mail.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var nextOrdinal: UInt64 = 0
    /// The ordinal of the step running now, or of the last one.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var currentOrdinal: UInt64 = 0
    /// Mail that checks have stepped since the last dispatch: the next `before` key's index.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var beforeIndex = 0
    /// Takes the running step has made: the next `inside` key's take.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var takeIndex = 0
    /// Replay: the recorded hand-outs, served in place of the mailbox. Nil when live.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var mailReplay: MailReplayStage<M.Mail>?
    /// Replay: the recorded `now` of the last staged mail a check stepped, served to its step
    /// and to the rest of the replay's segment, as live served the wake's `now` to the wake's
    /// segment, until a later staged mail overwrites it, the entry's own work starts or the
    /// segment ends. It doesn't set `cachedNow`.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var productsNow: TurnInstant?
    /// Live: called with each hand-out, for the adopter's record. A check's mail, before it
    /// steps, with the check's `now`; a non-empty mid-step take, with nil. Empty takes aren't
    /// passed.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onMailTaken: ((MailRecordKey, [M.Mail], TurnInstant?) -> Void)?
    /// Replay: called with a divergence, which fails the adopter's replay run. With none set, a
    /// divergence stops the process.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onReplayDivergence: ((TurnReplayDivergence) -> Void)?
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
    /// the adopters that set it are in this package. An observer: it must not send, arm or
    /// otherwise change the core.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onDiagnostic: ((TurnDiagnostic) -> Void)?
    /// Tells this core's completions from another core's (a replaced core).
    @usableFromInline let incarnation: UInt64
    @usableFromInline let queueLimit: Int
    @usableFromInline let maxReleasesPerBatch: Int
    @usableFromInline let clock: any TurnClock
    /// The mailbox, when the machine takes mail (`Mail` isn't `Never`); its actor stores
    /// this same instance.
    public let mailbox: TurnMailbox<M.Mail>?
    /// The cancelled `.cancelsCall` callers, when the machine has barriers (`CancelledCallers`).
    @usableFromInline let cancelledCallers: CancelledCallers?

    /// - Parameters:
    ///   - machine: the machine in its initial state.
    ///   - queueLimit: how many normal inputs may be queued at once.
    ///   - maxReleasesPerBatch: how many queued inputs a hold's release lets step per batch;
    ///     abandonments and sends that arrive during the batch don't count.
    ///   - clock: what `Turn.now`, deadlines and timers read and sleep on.
    ///   - mailboxCapacity: how much mail the mailbox holds at once, and how much one entry steps;
    ///     at least 1. Ignored for a machine without mail.
    ///
    /// Only a `PlainData` machine can be run: `@PlainData` writes that conformance and checks
    /// every stored field, so a machine that stores a class or a closure doesn't compile here.
    /// For a machine with no behavior (`Behavior == Void`); one that has a behavior uses
    /// `init(machine:behavior:…)`.
    public convenience init(_ machine: M, queueLimit: Int, maxReleasesPerBatch: Int, clock: some TurnClock, mailboxCapacity: Int = 8)
    where M: PlainData, M.Behavior == Void {
        self.init(machine: machine, behavior: (), queueLimit: queueLimit, maxReleasesPerBatch: maxReleasesPerBatch,
                  clock: clock, mailboxCapacity: mailboxCapacity)
    }

    /// A core for a machine with a behavior (`TurnMachine.Behavior`): what its steps call and
    /// read, fixed for the core's lifetime. The other parameters are `init(_:queueLimit:…)`'s.
    public init(machine: M, behavior: M.Behavior, queueLimit: Int, maxReleasesPerBatch: Int, clock: some TurnClock, mailboxCapacity: Int = 8) where M: PlainData {
        // `fatalError`, not `precondition`: its message prints in release builds too.
        if M.self is AnyClass { fatalError("TurnCore: the machine must be a value type, not \(M.self)") }
        if queueLimit < 0 { fatalError("TurnCore: queueLimit must not be negative") }
        if maxReleasesPerBatch < 1 { fatalError("TurnCore: maxReleasesPerBatch must be at least 1") }
        self.machine = machine
        self.behavior = behavior
        self.queueLimit = queueLimit
        self.maxReleasesPerBatch = maxReleasesPerBatch
        self.clock = clock
        self.incarnation = UInt64.random(in: UInt64.min ... UInt64.max)
        self.mailbox = Self.usesMailbox ? TurnMailbox(capacity: mailboxCapacity) : nil
        self.cancelledCallers = Self.usesBarriers ? CancelledCallers() : nil
    }

    deinit {
        assert(waiters.isEmpty, "TurnCore: a caller was never answered")
        sleeper?.cancel()
    }

    // MARK: The deadline heap

    /// At most this many live due entries step per wake; the rest steps on the next wake, and
    /// other work queued on the actor can run first (§3.6 of the plan). Separate from
    /// `maxReleasesPerBatch`.
    @inlinable static var maxFiresPerWake: Int { 64 }
    /// At most this many stale entries are popped per wake, due ones and the silent head drop
    /// together; the rest waits for the next wake or a compaction.
    @inlinable static var maxStalePopsPerWake: Int { 256 }
    /// A compaction needs at least this many stale entries, and at least half the heap stale.
    @inlinable static var compactionFloor: Int { 64 }

    /// Whether `entry`'s request is open, its follow-up's gate deadline still pending, or its
    /// timer still its key's current one.
    @inlinable func deadlineIsLive(_ entry: DeadlineEntry) -> Bool {
        switch entry.kind {
        case .timer: return rt.timerKeys[entry.ticket] != nil
        case .barrier: return rt.barrierTimers[entry.ticket] != nil
        case .request: break
        }
        let id = RequestID(raw: entry.ticket)
        if rt.open[id] != nil { return true }
        return Self.usesFollowUps && rt.gateDeadlineLive(id)
    }

    /// Drops the stale entries in O(n) once they are at least `compactionFloor` and half the heap,
    /// at amortized O(1) per invalidation. Right after an arm or a wake, the heap holds at most
    /// `max(compactionFloor, 2 × live) + 1` entries; cancels in between only count, so the bound
    /// holds after the next compaction check, not at every instant. Never during a wake (its due
    /// entries are outside the heap but still counted). The sleeper isn't re-armed: a removed
    /// target costs one wake that steps nothing.
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
        if Self.usesMailbox, let mailbox { stats.refusedMail = mailbox.refusedCount }
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
        if Self.usesMailbox, let productsNow { return productsNow }
        if let cachedNow { return cachedNow }
        let now = clock.now
        cachedNow = now
        onDiagnostic?(.clockRead)
        return now
    }

    // MARK: Replay

    /// Replays the mailbox from `entries` (a record's hand-outs): the mailbox isn't read, checks step
    /// the staged `before` mail and takes return the staged `inside` ones. Once, on a fresh
    /// core, before the first entry, any post and any call: installed later, it stops the
    /// process (an ordinal or a mail already taken, a post already made, or a call already made
    /// would replay against a record it isn't in). A core without a mailbox has no mail to
    /// replay: installing one there stops too. The core stays in replay mode for good,
    /// after `finishReplay()` too, so `.cancelsCall` keeps stopping.
    package func replayMail(_ entries: [MailRecordEntry<M.Mail>]) {
        if mailbox == nil || nextOrdinal != 0 || beforeIndex != 0 || (mailbox?.watermark ?? 0) != 0
            || nextInput != 0 || !waiters.isEmpty || mailReplay != nil || inSegment || borrows != 0 {
            fatalError("TurnCore: replayMail after the first entry; install a replay before any input")
        }
        mailReplay = MailReplayStage(entries)
    }

    @inlinable func diverged(_ divergence: TurnReplayDivergence) {
        mailReplay?.removeFirst()
        guard let onReplayDivergence else { fatalError("TurnCore: the replay diverged from its record: \(divergence)") }
        onReplayDivergence(divergence)
    }

    /// A boundary: a non-mail step is dispatched, an input is admitted (whatever the
    /// admission's outcome: stepped, parked or refused), or another entry starts its own work
    /// (`TurnActor.entryBoundary`). It takes the next ordinal, so a mail's `before` key names
    /// the boundary after which it stepped. In replay, anything still staged for an earlier
    /// place is unconsumed.
    @inlinable func noteDispatch() {
        guard Self.usesMailbox else { return }
        if mailReplay != nil {
            while let head = mailReplay?.first {
                if head.key.step < nextOrdinal {
                    diverged(.unconsumed(head.key))
                } else if case .before(let step, _) = head.key, step == nextOrdinal {
                    diverged(.unconsumed(head.key))
                } else {
                    break
                }
            }
        }
        currentOrdinal = nextOrdinal
        nextOrdinal &+= 1
        beforeIndex = 0
        takeIndex = 0
    }

    /// A take inside the running step: the staged entry for its key, or nothing.
    @inlinable func serveTake(_ key: MailRecordKey) -> [M.Mail] {
        guard let head = mailReplay?.first, head.key == key else { return [] }
        mailReplay?.removeFirst()
        return head.mail
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
        noteDispatch()
        enterStep(input)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: caller)
        machine.handle(input, &turn)
    }

    @inlinable func stepStale(_ input: M.Input) {
        noteDispatch()
        enterStep(input)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        machine.handleLateResult(input, &turn)
    }

    @inlinable func stepAbandoned(_ id: RequestID, _ why: Abandonment) {
        noteDispatch()
        enterStep(nil)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        machine.handleAbandoned(id, why, &turn)
    }

    @inlinable func stepMail(_ mail: M.Mail) {
        enterStep(nil)
        defer { leaveStep() }
        var turn = MailTurn<M>(core: self)
        machine.handleMail(mail, &turn)
    }

    /// A query is a step: its answer gets the turn, so it can change state and take mail. It takes
    /// a dispatch ordinal, so a recorded core's outside queries replay in order; a read that must
    /// not count goes through `read`.
    @inlinable func stepAnswer(_ query: M.Query) -> M.Answer {
        if borrows < 0 { fatalError("TurnCore: query was called from inside a step") }
        // Before the ordinal: a query from inside a read stops here, never as a replay divergence.
        if borrows > 0 { fatalError("TurnCore: a step was entered while a read is open") }
        noteDispatch()
        enterStep(nil)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        return machine.answer(query, &turn)
    }
}
