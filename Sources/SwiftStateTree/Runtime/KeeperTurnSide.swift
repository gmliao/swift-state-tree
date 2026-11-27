// Sources/SwiftStateTree/Runtime/KeeperTurnSide.swift
//
// The turn side and the turn's staged outputs (#700 K1b-5a). A turn body changes keeper state
// inline and stages its effects: a recorder submission, a continuation to resume, a task to
// start. The keeper flushes them in the order they were staged, before the body's first
// suspension, and before every call out of the keeper during the body (`LandKeeper.callOut`),
// so code outside the keeper sees the effects in today's order.

import Foundation

/// One effect a turn staged.
package enum TurnEffect {
    /// A recorder submission: `apply` runs after every earlier submission. `label` names the
    /// entry for the submission trace in tests.
    case submission(label: String, apply: @Sendable () async -> Void)
    /// Anything else that must wait for the flush: a continuation's resume, a task's start.
    case action(() -> Void)
}

/// The effects a turn staged, in staging order. Owned by the keeper's `withTurn` for one body
/// call, passed to the body `inout`, and flushed exactly once.
package struct TurnOutputs {
    private var effects: [TurnEffect] = []
    /// The last submission any flush of this turn made, across every flush (one before each
    /// call out, and the final one): what `withTurnSubmitting` returns.
    package fileprivate(set) var lastSubmission: RecorderSubmission?

    package init() {}

    /// Nothing staged.
    package var isEmpty: Bool { effects.isEmpty }

    /// Stages a recorder submission. Its bookkeeping (the submission count, a stream index)
    /// is the caller's, done inline before this call.
    package mutating func stageSubmission(_ label: String, _ apply: @escaping @Sendable () async -> Void) {
        effects.append(.submission(label: label, apply: apply))
    }

    /// Stages an effect that must not run before the flush. The action must not enter the keeper
    /// synchronously, nor touch its model: a `callOut`'s flush runs it inside the hold. At a body's end it runs after the depth has dropped, where the guarded
    /// entries wouldn't refuse it; when a `callOut` flushes first it runs at depth 1, where they
    /// refuse it and the call out is refused before the call.
    package mutating func stage(_ action: @escaping () -> Void) {
        effects.append(.action(action))
    }

    /// Removes and returns every staged effect, in staging order.
    fileprivate mutating func takeAll() -> [TurnEffect] {
        defer { effects.removeAll(keepingCapacity: false) }
        return effects
    }
}

/// What a turn body reaches outside its state: the keeper's tables it changes inline and the
/// references its flush needs. A stored property of the keeper, borrowed `inout` by one body
/// call at a time (`LandKeeper.withTurn`), so a callback that re-enters the keeper during the
/// body can't reach it.
///
/// K1b-5a's first step holds only the recorder submission tracker. The continuation tables,
/// the services, the job handles and `drainTask` move in with the bodies that change them.
package struct KeeperTurnSide {
    private let submissions: ReevaluationSubmissionTracker
    /// The action flow's tables (#700 K1b-5 rev 2.3 D11): job handles, slot waiters, test
    /// waiters and watchers.
    var actions = KeeperActionTables()
    /// Errors held for callers that haven't read them, by the ID the model holds (`InputResult`'s
    /// `.failed`): a value the model's results name, beside it until K2 (#700).
    var failures: [FailureID: any Error] = [:]
    /// The callers of `debugFreeze` and `waitForInFlightWorkForTesting`, woken when the in-flight
    /// work count reaches zero.
    var debugDrainWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    /// Tickless lands: callers waiting for their input's turn, by input sequence. Actions get
    /// their own response; other inputs get an empty one (or the handler's error).
    var inputTurnWaiters: [Int64: CheckedContinuation<InputOutcome, any Error>] = [:]
    /// A core's steps waiting for an input turn (#700 K2-1): `inputTurnWaiters` for a flow that
    /// can't await. Empty on the keeper's own side (`actionTableViolations`).
    var coreInputReplies = KeeperCoreInputReplies()
    /// Tickless inputs waiting for `debugResume()`.
    var debugHeldInputs: [CheckedContinuation<Void, Never>] = []
    /// The replay fields (D17): set on a re-evaluation keeper, nil on a live one, so a body's
    /// write keeps its mode guard and unwraps inside it.
    var replay: ReplayFields?
    /// Joins waiting for a leave of their player in flight (#943), parked by player, released
    /// by the segment that ends the leave's window (`endLeaveInFlight`), or resumed with
    /// `CancellationError` by the waiter's own cancel, whichever takes it first. Moves onto the
    /// turn core's barrier wait (#953).
    var leaveEnds = KeyedBarrierWaits<PlayerID>()
    /// Tests: the waiters' cancels, by outcome (`leaveEndWaiterCancelsForTesting`).
    var leaveEndWaiterCancelsForTesting: (removed: Int, foundGone: Int) = (0, 0)
    /// Tests: callers of `waitForLeaveEndWaitersForTesting`, by watcher ID.
    var leaveEndWaiterWatchersForTesting: [UInt64: (player: PlayerID, count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    /// Tests: callers of `waitUntilDrainStartedForTesting`, resumed when the drain's handle is
    /// installed.
    var drainStartedWaitersForTesting: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Tests: callers of `waitForFailureForTesting`, resumed when the land fails.
    var failureWaitersForTesting: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    /// An inside request: a turn asks for a sync-only turn right after it (a turn can't run
    /// inside a turn). One pending; a later inside request of the same binding joins it, one of a
    /// newer binding replaces it (the scheduled task reads the slot when it runs), and an outside
    /// request through the same port consumes it.
    var pendingSyncTurnAfterTurn: SyncTurnFollowUp?
    /// Server inputs in flight a land accepts (#387), from the environment at init; tests set it.
    /// Host configuration, not keeper state: off the model, as it was off the actor's.
    var serverInputMaxInFlight: Int = ServerInputLimits.maxInFlightPerLand()
    /// `forceShutdown` callers waiting for the shutdown turn (or for a drain that dropped its
    /// input), resumed when it completes.
    var shutdownTurnWaiters: [CheckedContinuation<Void, Never>] = []
    /// The empty-land destroy timer's ticket (D15.1, D16), beside the job handles.
    var destroyTicket: DestroyTicket?
    /// Tests (#700 K2-1's differential): the last ticket `replaceDestroyTicket` issued, kept
    /// after a cancel clears the slot, so a test can see whether its staged start installed a
    /// task and whether that task was cancelled. Kept only when `keepsLastDestroyTicketForTesting`
    /// is set, so a production keeper doesn't extend a cancelled ticket's (and its task's) life.
    var lastDestroyTicketForTesting: DestroyTicket?
    var keepsLastDestroyTicketForTesting = false
    /// Each player's services (#700 K1b-4; moved here by the move, D10): `LandServices` holds
    /// references. Written in the same synchronous segment as every insert and removal of the
    /// model's `players`, keyed by the entry's generation, so a late writer never removes a newer
    /// entry's services. K2 replaces it with the turn core's table.
    var playerServices: [PlayerID: (generation: Epoch, services: LandServices)] = [:]
    /// Tests only: called at the probe labels ("turn-begin", "turn-end", ...) on the keeper's
    /// executor.
    var probe: (@Sendable (String) -> Void)?
    /// Tests only (#700 K2-1's ordered trace): called for each effect a flush runs, in order,
    /// before it runs: "submission <label>" or "staged action".
    var flushTraceForTesting: (@Sendable (String) -> Void)?
    /// Tests: the tracker of this side's record submissions, which a test core waits on.
    var submissionsForTesting: ReevaluationSubmissionTracker { submissions }
    /// Tests only: a copy of the keeper's hold points, which `installHolds` sets with the keeper's,
    /// for the tasks a body's staged starts begin.
    var holdPoints = HoldPoints<LandKeeperHoldPoint>()

    /// The shared references a body reaches (#700 K1b-5 move, §3.1): the very objects the keeper
    /// holds, so a body uses them without the actor.
    /// Named apart from the keeper's own members (the census reads a label stored twice as one
    /// field with two homes); each is a copy of the same reference.
    let sharedCollector: KeeperOutputCollector
    /// The keeper's sequence lease: a handler step lends the model's counter through it to the
    /// step's contexts (#700 K1b-5 D15.3).
    let sharedSequenceLease: KeeperSequenceLease
    let sharedDrainFlag: KeeperDrainFlag
    let sharedTransportFailure: LandFailureMailbox
    /// The attached transport: the keeper sets it with its own at both of its assignments.
    var attachedTransport: (any LandKeeperTransport)?

    /// The keeper, for a body's staged starts only (D14): a staged action that starts a task
    /// whose first await is a hold reaches the keeper through it. Weak, and never read by a body
    /// for anything else: a body changes only the model and the side.
    let keeperReference: KeeperReference
    /// The submitter a context's `serverInputs` gets: the keeper's.
    let serverInputs: ServerInputSubmitter
    /// The keeper's drain handle (`LandKeeper.drainHandle`), the same box.
    let sharedDrainHandle: KeeperDrainHandle
    /// The keeper's step-scope counters (`lateStepOutputs`, `destroyHandlerOutputsDropped`),
    /// the same counters.
    let sharedLateStepOutputs: LateStepOutputCounter
    let sharedDestroyHandlerOutputsDropped: LateStepOutputCounter
    /// The keeper's `readOnlyHandlerOutputsDropped`: CanJoin's and the sync handler's scopes count there.
    let sharedReadOnlyHandlerOutputsDropped: LateStepOutputCounter
    /// Tests: whether a late step output asserts (debug builds) instead of only counting.
    var lateStepOutputAssertsForTesting = true
    /// The keeper's bound sync requester (`LandKeeper.boundRequester`), the same box.
    let sharedBoundRequester: KeeperBoundRequester
    /// The land's abandoned-resolver counter (`LandKeeper.abandonmentCounter`), for the job caps.
    let sharedAbandonmentCounter: LandAbandonmentCounter

    /// The land's failure, readable from any isolation (`LandKeeper.failure`).
    var failure: LandFailure? { sharedDrainFlag.failure }
    /// Whether the land is draining (`LandKeeper.isDraining`).
    var isDraining: Bool { sharedDrainFlag.isSet }

    /// Removes the drain-start waiters, to resume once the drain's handle is installed.
    mutating func takeDrainStartedWaitersForTesting() -> [CheckedContinuation<Void, Never>] {
        defer { drainStartedWaitersForTesting.removeAll() }
        return Array(drainStartedWaitersForTesting.values)
    }

    /// Removes the failure waiters, to resume once the land's failure is applied.
    mutating func takeFailureWaitersForTesting() -> [CheckedContinuation<Bool, Never>] {
        defer { failureWaitersForTesting.removeAll() }
        return Array(failureWaitersForTesting.values)
    }

    /// Resumes the shutdown turn's waiters.
    mutating func resumeShutdownTurnWaiters() {
        let waiters = shutdownTurnWaiters
        shutdownTurnWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Cancels the empty-land destroy timer, and a start staged before this that hasn't
    /// installed its task yet (D16).
    mutating func cancelDestroy() {
        if destroyTicket != nil { probe?("destroy-timer-cancelled") }
        destroyTicket?.cancel()
        destroyTicket = nil
    }

    /// A new ticket in the slot; the old one's timer is cancelled.
    mutating func replaceDestroyTicket() -> DestroyTicket {
        destroyTicket?.cancel()
        let ticket = DestroyTicket()
        destroyTicket = ticket
        if keepsLastDestroyTicketForTesting { lastDestroyTicketForTesting = ticket }
        return ticket
    }

    /// Removes the watchers of `key` and returns their continuations, to wake later.
    mutating func takeSlotWatchers(_ key: KeeperSlotWatchKey) -> [AsyncStream<Void>.Continuation] {
        guard !actions.slotWatchers.isEmpty else { return [] }
        return actions.slotWatchers.removeValue(forKey: key)?.map(\.continuation) ?? []
    }

    /// The services of `entry`, `playerID`'s entry read by the caller: the table's entry whose
    /// generation is the entry's.
    func currentPlayerServices(of playerID: PlayerID, entry: KeeperPlayerEntry) -> LandServices? {
        guard let services = playerServices[playerID], services.generation == entry.generation else { return nil }
        return services.services
    }

    /// Removes `playerID`'s services if they are the entry of `generation`'s: a newer entry's
    /// stay.
    mutating func removePlayerServices(of playerID: PlayerID, generation: Epoch) {
        if playerServices[playerID]?.generation == generation {
            playerServices.removeValue(forKey: playerID)
        }
    }

    /// Intake (and delivery) check: once the drain has started (`isDraining`, set in the same
    /// segment as the emptiness check), no input is accepted, so nothing is appended after the
    /// drain took the pending inputs.
    func rejectIfLandClosed() throws {
        guard isDraining else { return }
        throw LandInputRejection.landClosed
    }

    init(
        submissions: ReevaluationSubmissionTracker,
        keeperReference: KeeperReference,
        drainHandle: KeeperDrainHandle,
        lateStepOutputs: LateStepOutputCounter,
        destroyHandlerOutputsDropped: LateStepOutputCounter,
        readOnlyHandlerOutputsDropped: LateStepOutputCounter,
        boundRequester: KeeperBoundRequester,
        abandonmentCounter: LandAbandonmentCounter,
        serverInputs: ServerInputSubmitter,
        collector: KeeperOutputCollector,
        sequenceLease: KeeperSequenceLease,
        drainFlag: KeeperDrainFlag,
        transportFailure: LandFailureMailbox,
        transport: (any LandKeeperTransport)?,
        replay: ReplayFields? = nil
    ) {
        self.submissions = submissions
        self.keeperReference = keeperReference
        self.replay = replay
        self.sharedDrainHandle = drainHandle
        self.sharedLateStepOutputs = lateStepOutputs
        self.sharedDestroyHandlerOutputsDropped = destroyHandlerOutputsDropped
        self.sharedReadOnlyHandlerOutputsDropped = readOnlyHandlerOutputsDropped
        self.sharedBoundRequester = boundRequester
        self.sharedAbandonmentCounter = abandonmentCounter
        self.serverInputs = serverInputs
        self.sharedCollector = collector
        self.sharedSequenceLease = sequenceLease
        self.sharedDrainFlag = drainFlag
        self.sharedTransportFailure = transportFailure
        self.attachedTransport = transport
    }

    /// Whether the attached transport runs the sync phase in the turn (a live keeper only):
    /// the keeper's `syncsInTurn`, read from a body. A port call: a body reads it inside
    /// `callOut`.
    func syncsInTurn<State>(_ behavior: KeeperBehavior<State>) -> Bool {
        guard behavior.config.mode == .live else { return false }
        // A core's tick or sync step carries its input's read (K2-1); K2-2's binding token
        // replaces it.
        if let carried = coreInputReplies.carriedSyncsInTurn { return carried && attachedTransport != nil }
        guard let keeper = keeperReference.keeper else { return false }
        return attachedTransport?.runsSyncPhaseInTurn(of: keeper) ?? false
    }

    /// Tells the attached transport which joins this pass consumed (a live keeper syncing in the
    /// turn only). A port call: a body makes it inside `callOut`.
    func noteJoinInputsConsumed<State>(_ behavior: KeeperBehavior<State>, _ results: [JoinInputResult]) {
        guard !results.isEmpty, syncsInTurn(behavior), let transport = attachedTransport else { return }
        transport.noteJoinInputsConsumed(results)
    }

    /// The transport's refusal of a stale join by its resolved player, only on the in-turn path
    /// as the keeper's `admitJoiningInTurn`; off that path the transport keeps its check by the
    /// requested player alone. A port call: a body makes it inside `callOut`.
    func refusesResolvedJoinInTurn<State>(_ behavior: KeeperBehavior<State>, playerID: PlayerID, sessionID: SessionID) -> Bool {
        guard syncsInTurn(behavior), let transport = attachedTransport else { return false }
        return transport.refusesResolvedJoin(playerID: playerID, sessionID: sessionID)
    }

    /// Whether the sync stream is recorded (the keeper's `recordsSyncStream`). A port call, as
    /// `syncsInTurn`.
    func recordsSyncStream<State>(_ behavior: KeeperBehavior<State>) -> Bool {
        behavior.config.mode == .live && behavior.reevaluationRecorder != nil && syncsInTurn(behavior)
    }

    /// Opens a handler call's scope (#700 K2-E) and binds it to a copy of `ctx`; the caller
    /// closes it when the handler returns. Outputs made through the copy before the close go
    /// where they go today, numbered at emit time; later ones are dropped and counted in
    /// `lateStepOutputs`. With `dropsOutputs` (a destroy handler, #893), every output is dropped
    /// and counted in `destroyHandlerOutputsDropped`.
    func openStepScope(_ ctx: LandContext, random: DeterministicRngService, droppingInto dropped: LateStepOutputCounter? = nil) -> (LandContext, StepScope) {
        let scope = StepScope(
            random: random,
            late: sharedLateStepOutputs,
            assertsOnLateOutput: lateStepOutputAssertsForTesting,
            dropsOutputs: dropped
        )
        var bound = ctx
        bound.stepScope = scope
        return (bound, scope)
    }

    /// Re-evaluation: notes that OnInitialize's `validate` threw on the recorded inputs (#593),
    /// once (the first error wins). A no-op on a live keeper, which has no replay fields.
    mutating func noteReplayedInitializeRefusal(_ error: any Error) {
        guard replay?.replayedInitializeRefusal == nil else { return }
        replay?.replayedInitializeRefusal = "OnInitialize's validate threw in replay: \(error)"
    }

    /// Submits to the recorder's serial sink now, in the body's segment (an entry whose count
    /// later code reads; §3.2's table keeps the rest staged).
    @discardableResult
    func submit(label: String, _ apply: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        submissions.submit(label: label, apply)
    }

    /// Applies the staged effects in staging order and empties `outputs`, keeping the last
    /// submission it made in `outputs.lastSubmission`. Not `mutating`: the keeper calls
    /// it on a copy of the side, so no access to its stored side is held while the actions run.
    package func flush(_ outputs: inout TurnOutputs) {
        for effect in outputs.takeAll() {
            switch effect {
            case let .submission(label, apply):
                flushTraceForTesting?("submission \(label)")
                outputs.lastSubmission = RecorderSubmission(task: submissions.submit(label: label, apply))
            case let .action(action):
                flushTraceForTesting?("staged action")
                action()
            }
        }
    }
}

/// A record submission the side's flush made to the recorder's serial sink: a handle a caller
/// awaits until the sink took the record. The side starts the work; a turn machine only carries
/// the handle to the effect that awaits it, so a machine's file names no task (lint-turns
/// `machine-file`: a machine's steps start no work).
package struct RecorderSubmission: Sendable {
    fileprivate let task: Task<Void, Never>

    /// Returns once the recorder's sink applied the submission.
    package func taken() async {
        await task.value
    }
}

/// A weak reference to the keeper, set once in its init before anything reads it (#700 K1b-5
/// move, D14): the side holds it, so a staged start reaches the keeper without a body holding it.
final class KeeperReference: @unchecked Sendable {
    weak var keeper: AnyObject?
}

/// The adapter bound by the first sync request of a keeper never attached (#546 L2a). Weak: the
/// adapter holds the keeper. A box the keeper and its side share, used on the keeper's executor
/// only, so a body binds it and a refusing entry reads it without an access to the side.
final class KeeperBoundRequester: @unchecked Sendable {
    weak var object: AnyObject?
    var port: (any LandKeeperTransport)? { object as? any LandKeeperTransport }
}

/// The model's sequence counter, lent to a handler step's contexts while the handler runs
/// (#700 K1b-5 D15.3). The handler holds only `&m.state`, so the counter leaves the model for the
/// step and comes back when it ends, in the step's `defer`: an emit takes its number at emit
/// time, as before, and the body's watermarks after the step read numbers that include the
/// handler's. A sync request is staged here, keyed on the tick its context captured, and ORed
/// into the model's table when the step ends.
///
/// Only one step is lent to at a time: a handler step runs in one synchronous segment. An
/// output that finds nothing lent (a context outside any step that passes outputs) is dropped
/// and counted; no keeper path makes one.
final class KeeperSequenceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: KeeperSequenceCounter?
    private var requests: [Int64: KeeperSyncRequests] = [:]
    private var unlent = 0
    private var takenWhileLent = 0
    private var assertsOnTakeWhileLent = true

    /// Lends the counter for one step.
    func lend(_ lent: KeeperSequenceCounter) {
        lock.withLock {
            precondition(counter == nil, "a handler step's sequence counter was lent twice")
            counter = lent
            requests = [:]
        }
    }

    /// Ends the step's lend: the counter, with the step's takes, and its staged requests.
    func end() -> (counter: KeeperSequenceCounter, requests: [Int64: KeeperSyncRequests]) {
        lock.withLock {
            guard let lent = counter else { preconditionFailure("a handler step's lend ended twice") }
            counter = nil
            defer { requests = [:] }
            return (lent, requests)
        }
    }

    /// An emitted event, numbered from the lent counter.
    func emit(_ event: AnyServerEvent, to target: EventTarget, tickId: Int64, into collector: KeeperOutputCollector) {
        lock.withLock {
            guard var lent = counter else {
                unlent += 1
                assertionFailure("A LandContext event was emitted outside a handler step; it was dropped")
                return
            }
            let sequence = lent.take()
            counter = lent
            collector.emittedEvents.append(KeeperEmittedEvent(sequence: sequence, tickId: tickId, event: event, target: target))
        }
    }

    /// A sync request, staged for the step's end.
    func requestSync(broadcastOnly: Bool, tickId: Int64) {
        lock.withLock {
            guard counter != nil else {
                unlent += 1
                assertionFailure("A LandContext sync request was made outside a handler step; it was dropped")
                return
            }
            if broadcastOnly {
                requests[tickId, default: KeeperSyncRequests()].syncBroadcastOnly = true
            } else {
                requests[tickId, default: KeeperSyncRequests()].syncNow = true
            }
        }
    }

    /// The outputs that found nothing lent.
    var unlentCount: Int { lock.withLock { unlent } }

    /// Counts a take from the model's own counter while it was lent (its value then is lost
    /// when the lease's counter replaces it). Returns whether to assert: debug builds stop
    /// unless a test turned that off.
    func noteTakenWhileLent() -> Bool {
        lock.withLock {
            takenWhileLent += 1
            return assertsOnTakeWhileLent
        }
    }
    /// How many takes from the model's counter happened while it was lent.
    var takenWhileLentCount: Int { lock.withLock { takenWhileLent } }
    /// Tests only: count a take while lent without stopping a debug build.
    func setAssertsOnTakeWhileLentForTesting(_ asserts: Bool) { lock.withLock { assertsOnTakeWhileLent = asserts } }
}

/// The keeper's drain in progress (single-flight). A box the keeper and its side share, used
/// on the keeper's executor only, so `failLand`'s staged start installs the handle from a body
/// and the keeper's async entries read it.
final class KeeperDrainHandle: @unchecked Sendable {
    var task: Task<Void, Never>?
}
