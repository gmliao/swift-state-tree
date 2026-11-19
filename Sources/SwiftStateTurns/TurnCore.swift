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
    /// `start` and `queue` calls after `endAll`.
    public var ignoredAfterEnd = 0
    /// `send`s refused (closed, withdrawn or over the queue limit), or queued and then withdrawn
    /// or closed (`end`, a supersede, `revoke`, `close`, `endAll`), which had no caller to answer.
    public var droppedSends = 0
    /// Completions and deadlines from another core (a replaced one), dropped.
    public var foreignCompletions = 0
    /// Batches whose released inputs were left for a later batch by the budget.
    public var drainContinuations = 0
    /// Calls answered with `CancellationError` under `.cancelsCall`.
    public var cancelledCalls = 0

    @inlinable public init() {}
}

/// What a test may wait for, reported synchronously on the actor where it happens.
public enum TurnDiagnostic: Sendable, Equatable {
    case queued(total: Int)
    case batchEnded(released: Int)
    case foreignCompletion
    /// A deadline woke (on time, or early because it was cancelled) for a request that had
    /// already closed, and did nothing.
    case staleDeadline
    /// A timer woke (on time, or early because it was cancelled) after it was replaced or
    /// dropped, and did nothing.
    case staleTimer
    case clockRead
}

/// The machine, the runtime and the step. Not `Sendable`: only its actor reaches it, through
/// a stored `let`.
public final class TurnCore<M: TurnMachine> {
    /// Changed only inside a step.
    @usableFromInline var machine: M
    @usableFromInline var rt = Runtime<M>()
    @usableFromInline var inStep = false
    @usableFromInline var inSegment = false
    /// Sends and calls made while a step or a batch was running, each with the scope-end clock
    /// at its arrival.
    @usableFromInline var queued = FIFO<(M.Input, InputID?, UInt64)>()
    /// While inputs are deferred (`queued`), the clock reading at each scope's latest end or
    /// supersede. A deferred input whose scope ended after it arrived is withdrawn when it is
    /// admitted. Emptied when `queued` drains, so it holds only one batch's ends.
    @usableFromInline var scopeEndsWhileDeferred: [M.Key: UInt64] = [:]
    @usableFromInline var scopeEndClock: UInt64 = 0
    @usableFromInline var waiters: [InputID: CheckedContinuation<M.Reply, any Error>] = [:]
    @usableFromInline var nextInput: UInt64 = 0
    @usableFromInline var drainScheduled = false
    @usableFromInline var counters = TurnStats()
    /// The batch's clock reading, taken on first use.
    @usableFromInline var cachedNow: TurnInstant?
    @usableFromInline var deadlineTasks: [RequestID: Task<Void, Never>] = [:]
    @usableFromInline var timerTasks: [M.Key: (generation: UInt64, task: Task<Void, Never>)] = [:]
    // Debug builds fill these (`effectsByInput`). Stored in every build, because inlined code
    // in a client compiled in another configuration may name them.
    /// The case name of the input stepping now.
    @usableFromInline var stepCase: String?
    @usableFromInline var effectCounts: [String: Int] = [:]
    /// Test-only: called on the actor, synchronously, where the event happens. Package access:
    /// the adopters that set it are in this package.
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
        for task in deadlineTasks.values { task.cancel() }
        for entry in timerTasks.values { entry.task.cancel() }
    }

    /// Reads the machine. Between steps only: from inside a step it stops the process.
    @inlinable public func read<R>(_ body: (borrowing M) -> R) -> R {
        if inStep { fatalError("TurnCore: the machine was read from inside its own step") }
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
        return stats
    }

    /// Debug builds: how many effects (`request` and `run`) each input case started, by the
    /// case's name, so an adopter's tests can assert zero for its hot inputs. Empty in release.
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
        if inStep { fatalError("TurnCore: a step was entered from inside a step") }
        inStep = true
        #if DEBUG
        stepCase = input.map(Self.caseName)
        #endif
    }

    @inlinable func leaveStep() {
        inStep = false
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
        var turn = Turn<M>(core: self, input: caller)
        machine.handle(input, &turn)
        leaveStep()
    }

    @inlinable func stepStale(_ input: M.Input) {
        enterStep(input)
        var turn = Turn<M>(core: self, input: nil)
        machine.handleLateResult(input, &turn)
        leaveStep()
    }

    @inlinable func stepAbandoned(_ id: RequestID, _ why: Abandonment) {
        enterStep(nil)
        var turn = Turn<M>(core: self, input: nil)
        machine.handleAbandoned(id, why, &turn)
        leaveStep()
    }

    @inlinable func stepAnswer(_ query: M.Query) -> M.Answer {
        if inStep { fatalError("TurnCore: query was called from inside a step") }
        enterStep(nil)
        var turn = Turn<M>(core: self, input: nil)
        let answer = machine.answer(query, &turn)
        leaveStep()
        return answer
    }
}
