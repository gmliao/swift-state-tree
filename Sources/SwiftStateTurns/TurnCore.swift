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
    /// Lane wakes that found the lane empty: an entry took the reports first.
    public var emptyLaneWakes = 0
    /// Posts refused because the lane was full (the first pending report wins).
    public var refusedReports = 0

    @inlinable public init() {}
}

/// What a test may wait for, reported synchronously on the actor where it happens.
public enum TurnDiagnostic: Sendable, Equatable {
    case queued(total: Int)
    case batchEnded(released: Int)
    case foreignCompletion
    /// A deadline woke (on time, or early because it was cancelled) for a request or a
    /// follow-up gate that had already closed, and did nothing.
    case staleDeadline
    /// A timer woke (on time, or early because it was cancelled) after it was replaced or
    /// dropped, and did nothing.
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
    /// The machine takes lane reports. A constant once specialized, as `usesFollowUps`: every
    /// lane path folds away for a machine that keeps the default (`Never`).
    @inlinable static var usesLane: Bool { M.LaneReport.self != Never.self }

    // Release builds skip the runtime exclusivity checks on the core's own state (#621): with
    // the core inlined into its adopter, each use of a stored var otherwise pays a
    // `swift_beginAccess`/`swift_endAccess` pair. The actor serializes every access, and the core
    // stops the process on the overlaps a check would catch, by the borrow rule of `borrows`
    // (a step inside a step or inside a read, nested or not; a read or a query inside a step).
    // It can't stop adopter code that the core runs
    // during its own accesses: `M.Key`'s `==` and `hash(into:)` (run inside mutations of `rt`,
    // `timerTasks` and `scopeEndsWhileDeferred`) and the deinits of inputs and keys the core
    // drops (`queued`, a withdraw, `removeAll`). Those must not call back into the actor; an
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
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var deadlineTasks: [RequestID: Task<Void, Never>] = [:]
    /// Tests: how many deadline tasks (requests' and follow-up gates') the core holds.
    package var deadlineTasksForTesting: Int { deadlineTasks.count }
    /// Tests: how many follow-up gates the core has launched; counted in debug builds only.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var gateLaunchesForTesting = 0
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var timerTasks: [M.Key: (generation: UInt64, task: Task<Void, Never>)] = [:]
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
    /// How many more lane reports this entry may step: `lane.capacity` at each entry, spent by
    /// the entry's lane take and by every check in its segment.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var laneBudget = 0
    /// Set while an epilogue's remainder wake is scheduled and hasn't started, so a flood of
    /// entries that spend their budget schedules one (a post's own wake isn't coalesced).
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var laneWakeScheduled = false
    /// A report's own step is running: its `Turn.takeReports()` returns nothing, and reports
    /// posted meanwhile step at the next check.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var inReportStep = false
    /// Tests: called on the actor at each lane check, after it reads its watermark and before
    /// its first removal, so a test can post there. Observe-only, apart from `post`.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onLaneCheckForTesting: (() -> Void)?
    /// Tests: called on the actor at the start of each lane wake (`laneWoke`), before its lane
    /// take; a test sees the wake boundaries with it. Observe-only.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onLaneWakeForTesting: (() -> Void)?
    /// The next non-report step's ordinal, counted over every step the core dispatches (inputs,
    /// releases, follow-ups, answers, completions, timers, abandonments); a lane record's keys
    /// name steps by it. Counted only for a machine that takes reports.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var nextOrdinal: UInt64 = 0
    /// The ordinal of the step running now, or of the last one.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var currentOrdinal: UInt64 = 0
    /// Reports checks have stepped since the last dispatch: the next `before` key's index.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var beforeIndex = 0
    /// Takes the running step has made: the next `inside` key's take.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var takeIndex = 0
    /// Replay: the recorded hand-outs, served in place of the lane. Nil when live.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var laneReplay: LaneReplayStage<M.LaneReport>?
    /// Replay: the recorded `now` served inside the report step running now. Scoped to that
    /// step: it doesn't set `cachedNow`.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var reportNow: TurnInstant?
    /// Live: called with each hand-out, for the adopter's record. A check's report, before it
    /// steps, with the check's `now`; a non-empty mid-step take, with nil. Empty takes aren't
    /// passed.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onReportsTaken: ((LaneRecordKey, [M.LaneReport], TurnInstant?) -> Void)?
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
    /// The lane, when the machine takes reports (`LaneReport` isn't `Never`); its actor stores
    /// this same instance.
    public let lane: TurnLane<M.LaneReport>?

    /// - Parameters:
    ///   - machine: the machine in its initial state.
    ///   - queueLimit: how many normal inputs may be queued at once.
    ///   - maxReleasesPerBatch: how many queued inputs a hold's release lets step per batch;
    ///     abandonments and sends that arrive during the batch don't count.
    ///   - clock: what `Turn.now`, deadlines and timers read and sleep on.
    ///   - laneCapacity: how many reports the lane holds at once, and how many one entry steps;
    ///     at least 1. Ignored for a machine without reports.
    ///
    /// Only a `PlainData` machine can be run: `@PlainData` writes that conformance and checks
    /// every stored field, so a machine that stores a class or a closure doesn't compile here.
    public init(_ machine: M, queueLimit: Int, maxReleasesPerBatch: Int, clock: some TurnClock, laneCapacity: Int = 8) where M: PlainData {
        // `fatalError`, not `precondition`: its message prints in release builds too.
        if M.self is AnyClass { fatalError("TurnCore: the machine must be a value type, not \(M.self)") }
        if queueLimit < 0 { fatalError("TurnCore: queueLimit must not be negative") }
        if maxReleasesPerBatch < 1 { fatalError("TurnCore: maxReleasesPerBatch must be at least 1") }
        self.machine = machine
        self.queueLimit = queueLimit
        self.maxReleasesPerBatch = maxReleasesPerBatch
        self.clock = clock
        self.incarnation = UInt64.random(in: UInt64.min ... UInt64.max)
        self.lane = Self.usesLane ? TurnLane(capacity: laneCapacity) : nil
    }

    deinit {
        assert(waiters.isEmpty, "TurnCore: a caller was never answered")
        for task in deadlineTasks.values { task.cancel() }
        for entry in timerTasks.values { entry.task.cancel() }
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
        if Self.usesLane, let lane { stats.refusedReports = lane.refusedCount }
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
        if Self.usesLane, inReportStep, let reportNow { return reportNow }
        if let cachedNow { return cachedNow }
        let now = clock.now
        cachedNow = now
        onDiagnostic?(.clockRead)
        return now
    }

    // MARK: Replay

    /// Replays the lane from `entries` (a record's hand-outs): the lane isn't read, checks step
    /// the staged `before` reports and takes return the staged `inside` ones. Before the first
    /// entry.
    package func replayReports(_ entries: [LaneRecordEntry<M.LaneReport>]) {
        laneReplay = LaneReplayStage(entries)
    }

    @inlinable func diverged(_ divergence: TurnReplayDivergence) {
        laneReplay?.removeFirst()
        guard let onReplayDivergence else { fatalError("TurnCore: the replay diverged from its record: \(divergence)") }
        onReplayDivergence(divergence)
    }

    /// A boundary: a non-report step is dispatched, or an input is admitted (whatever the
    /// admission's outcome: stepped, parked or refused). It takes the next ordinal, so a report's
    /// `before` key names the boundary after which it stepped. In replay, anything still staged
    /// for an earlier place is unconsumed.
    @inlinable func noteDispatch() {
        guard Self.usesLane else { return }
        if laneReplay != nil {
            while let head = laneReplay?.first {
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
    @inlinable func serveTake(_ key: LaneRecordKey) -> [M.LaneReport] {
        guard let head = laneReplay?.first, head.key == key else { return [] }
        laneReplay?.removeFirst()
        return head.reports
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

    @inlinable func stepReport(_ report: M.LaneReport) {
        enterStep(nil)
        inReportStep = true
        defer {
            inReportStep = false
            leaveStep()
        }
        var turn = Turn<M>(core: self, input: nil)
        machine.handleReport(report, &turn)
    }

    @inlinable func stepAnswer(_ query: M.Query) -> M.Answer {
        if borrows < 0 { fatalError("TurnCore: query was called from inside a step") }
        noteDispatch()
        enterStep(nil)
        defer { leaveStep() }
        var turn = Turn<M>(core: self, input: nil)
        return machine.answer(query, &turn)
    }
}
