// The keeper's model as a turn machine (#700 K2-1, plan
// `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` §4). Not wired: the keeper doesn't
// drive a core yet (K2-2). K2-1's differential drives a test core with it and compares the result
// with the keeper's own path, through the very bodies and segments both call.

import Foundation
import SwiftStateTurns

/// The keys the machine's work belongs to (plan §4.1). The ids are today's: an entry is named by
/// its player and its generation (the `Epoch` in `entryGenerations`), a sync binding by its
/// `GenerationTable` ticket, and a freeze caller's wait by its input ID.
enum KeeperKey: Hashable, Sendable {
    case land
    case initialization
    case entry(PlayerID, Epoch)
    case syncBinding(SyncTurnTicket)
    /// One freeze caller's wait: each caller gets its own deadline, as `debugFreeze` gives each
    /// call its own timer (Review on #948).
    case freezeWait(InputID)
}

/// What a caller waits on in the core's barrier (#953, `Turn.wait`).
enum KeeperBarrierKey: Hashable, Sendable {
    /// The end of `player`'s leave in flight of the entry `generation` (#943): released by the
    /// step that ends it, the leave's own (`endLeaveInFlight`) or the drain's start
    /// (`endAllLeavesInFlight`), as the keeper's `leaveEnds.release` (the barrier plan's §4).
    case leaveEnd(PlayerID, generation: Epoch)
}

/// What a waiting caller holds; it comes back once, released or ended.
enum KeeperBarrierPayload: Sendable {
    /// A join waiting for a leave in flight: J2c runs with it when the leave ends.
    case joinAfterLeave(KeeperJoinDecided, leavingGeneration: Epoch, syncsInTurn: Bool)
}

/// The core's barrier waits (K2-2 plan, commit 2), as plain values: each caller's input ID.
/// "Barriers, not holds" (K2 §4.2): the core parks no intake behind a key, so a query can't
/// overtake a parked call. The freeze's barrier holds an intake on the side instead
/// (`heldWhileFrozen`), released by the step that opens it.
@PlainData
struct KeeperCoreBarrierWaits: Sendable, Equatable {
    /// A freeze's callers, by generation: answered true once the in-flight work is 0 with that
    /// generation still in effect, false at its timeout or its release.
    var freeze: [UInt64: [InputID]] = [:]
    /// Callers waiting for the initialization (its closed case is answered in commit 1).
    var initialized: [InputID] = []
    /// The drain's callers (a `.shutdown`, and a second one that joins it): answered by
    /// `.drainFinished`'s step (K2-2 commit 1b).
    var drained: [InputID] = []
    /// Stops that arrived before the initialization ended (`forceShutdown`'s `ensureInitialized`):
    /// admitted at its end, never answered by a drain that ends before it (Review r1 on #969,
    /// MF4: a land failure's drain during OnInitialize's resolvers).
    var stopsAwaitingInitialization: [InputID] = []

    var isEmpty: Bool { freeze.isEmpty && initialized.isEmpty && drained.isEmpty && stopsAwaitingInitialization.isEmpty }
}

/// Who an entry speaks for: the three identities every player entry takes.
struct KeeperCaller: Sendable {
    let playerID: PlayerID
    let clientID: ClientID
    let sessionID: SessionID?
}

/// The entries that `send` or `sendAndWait`, and the results that come back from `run`
/// (plan §4.1). A result input carries what its segment needs to resume and the ticket captured
/// when its request went out, which the step checks against the current state first.
enum KeeperInput<State: StateNodeProtocol>: Sendable {
    // Entries.
    /// `cancelled`: the caller's task's cancellation, read by the sender (a core step runs on
    /// the core's driver task, so it can't read the caller's; Review on #948, as #944 did).
    /// `cancellation`: the set-once flag the caller's `onCancel` sets, synchronously, once it is
    /// cancelled after the send; the intake's step reads it where the keeper reads
    /// `Task.isCancelled`, after the freeze's barrier (#948 round 3, as `awaitActionResult`'s
    /// `box.callerCancelled`).
    case action(ActionEnvelope, KeeperCaller, cancelled: Bool = false, cancellation: ActionJobCallerCancellation? = nil)
    case clientEvent(AnyClientEvent, KeeperCaller)
    /// A join. `syncsInTurn`: the driver's read of whether the attached transport runs the
    /// sync phase in turn, which the transport's admission needs (see `.tickDue`); the join's
    /// stages and continuations carry it on. K2-2's binding token replaces it.
    case join(LandKeeper<State>.JoinCall, syncsInTurn: Bool)
    case leave(KeeperCaller)
    /// The tick driver's input. The fold and its start instant are the two arguments
    /// `runTickTurn` takes from the actor today; the start is read only for a fold.
    /// A tick is due. `syncsInTurn`: the driver's read of whether the attached transport runs
    /// the sync phase in turn (the keeper's `syncsInTurn`), made outside the step as `runTick`
    /// makes it outside its body; K2-2's binding token carries it.
    /// `epoch`: the `loopEpoch` the owner's loop Task captured (plan §13.1); one that isn't
    /// current is a no-op. Nil: a driver without loops (the tests' `drive`), never stale.
    case tickDue(fold: PendingFold?, foldStart: ContinuousClock.Instant?, syncsInTurn: Bool, epoch: UInt64? = nil)
    /// The sync loop is due, with the driver's reads made outside the step, as `runSync` makes
    /// them: `now`, the tick loop's next deadline (nil without a tick loop), whether a fold is
    /// already pending (the driver holds `pendingFold`), and `syncsInTurn` (see `.tickDue`).
    case syncDue(now: ContinuousClock.Instant, tickDeadline: ContinuousClock.Instant?, foldPending: Bool, syncsInTurn: Bool, epoch: UInt64? = nil)
    case freeze(generation: UInt64, timeout: Duration)
    case resume(generation: UInt64)
    case shutdown
    case awaitInitialized
    /// `submitSyncStream`'s drafts (the adapter's awaited callers: the `.legacyCycle` branch, the
    /// disconnect's clear). `outsideTurn`: the adapter's standalone registration and fallback
    /// admission, as the keeper's entry takes it (K2 §16 item 6).
    case syncStreamDraft([SyncStreamDraft], outsideTurn: Bool)

    // Results of `run`.
    /// A join's resolvers returned: the stage names the segment that resumes, with what it
    /// carries; `caller` is the join's. No ticket: the only check is the segments' own (the
    /// drain, and `appendOnJoin`'s on `capture.entryGeneration`), as on the keeper.
    case joinStepped(KeeperJoinStage<State>, caller: InputID?, Result<[String: HeldResolverOutput], any Error>)
    /// A leave's OnLeave resolvers returned: L2 resumes with the capture L1 took, and the
    /// continuation says where the leave's answer goes. No ticket: L1 removed the entry, and L2
    /// re-reads only `isDraining`, as on the keeper.
    case leaveStepped(LandKeeper<State>.LeaveCapture, KeeperContinuation, Result<[String: HeldResolverOutput], any Error>)
    /// An action job's resolvers returned (`.actionJob`'s run): the worker's segment
    /// (`completeActionBody`) checks the job, its ticket and its caller's cancel, as on the keeper.
    case actionResolved(sequence: Int64, Result<[String: HeldResolverOutput], any Error>)
    /// A completed job's abandoned resolvers ended (`.actionJobRelease`'s run): the job leaves
    /// the caps, as the keeper's `releaseCompletedActionJob` does from the abandonment's `onEnded`.
    case actionJobReleased(sequence: Int64)
    /// A `sendAndWait` for the job's slot (`awaitActionResult`): the outcome at once when the
    /// slot holds it, or when the job fills it. The caller's cancel rides the job's box, which
    /// the waiting caller cancels itself (K2-2 plan, commit 0), not this input.
    case awaitActionResult(sequence: Int64)
    /// The initialization's driver (K2-2 commit 1a): the owner sends `.initialize` once `.land`
    /// is started; each later request comes back as one of these. `initializeResolved` carries
    /// what `initializeBegin` built for the resolvers (closures, a context: never the model's),
    /// their result, and the effect's task's cancellation, read where the resolvers ran.
    case initialize
    case initializeResolved(LandKeeper<State>.InitializeResolving, Result<LandContext, any Error>, initializationTaskCancelled: Bool)
    /// The initialize record was taken by the recorder.
    case initializeRecorded
    /// The owner configured its loops (`.startLoops`): the two flags it read.
    case initializeDone(tickLoopConfigured: Bool, syncLoopConfigured: Bool)
    /// The destroy drain (K2-2 commit 1b). `.drainStart`: the owner held the drain's start and
    /// cancelled its loops (M7); the step runs `drainBegin`. A destroy handler's resolvers
    /// returned, with the step `nextDestroyStep` built (closures, a context: never the model's).
    case drainStart
    case destroyHandlerResolved(LandKeeper<State>.DestroyHandlerStep, Result<LandContext, any Error>)
    /// AfterFinalize returned (its outputs dropped, #893).
    case afterFinalizeReturned
    /// A tick land's tick record was taken by the recorder: the tick's in-flight work ends here,
    /// not in the tick's step (the tick-record hold, plan §13.1).
    case tickRecordTaken(tickId: Int64)
    /// The stop's shutdown turn record was taken (plan §13.3).
    case shutdownRecorded
    /// A tickless input turn's record was taken by the recorder: its callers resume with the
    /// results the effect carried (K2-2 plan, item 15).
    /// `endsTickWork`: the drain was a tick's, whose in-flight work ends with it.
    case recordTaken(applied: [LandKeeper<State>.PendingItem], results: [Int64: InputResult], endsTickWork: Bool)
    /// An input drain a flow's wait scheduled (the keeper's `scheduleInputDrain` task), queued
    /// behind `.land`.
    case inputDrainDue
    /// `onLandDestroyed` returned (`.notifyTransport`'s run).
    case drainFinished
    /// The owner starts `.land` at initialization, which a step's outputs for it need (K2-1: the
    /// test harness's start; K2-2: the core's initialization).
    case startLand
    /// One freeze caller's timeout (the core timer on `.freezeWait(caller)`): that caller gets
    /// false.
    case freezeTimedOut(generation: UInt64, caller: InputID)
}

/// Which inputs `handle` routes (K2-1, then K2-2a), and where each of the rest is routed (Review,
/// 2026-11-27). `routeName` is exhaustive, so a new case must be named; the census test checks
/// that the two lists split the cases, and the differential that no deferred input is sent.
enum KeeperInputRoutes {
    static let routed: Set<KeeperInputRoute> = [
        .tickDue, .syncDue, .recordTaken, .inputDrainDue, .join, .joinStepped, .leave, .leaveStepped, .action, .clientEvent, .startLand,
        .actionResolved, .actionJobReleased, .awaitActionResult,
        .freeze, .resume, .awaitInitialized, .freezeTimedOut,
        .syncStreamDraft,
        .initialize, .initializeResolved, .initializeRecorded, .initializeDone,
        .shutdown, .drainStart, .destroyHandlerResolved, .afterFinalizeReturned, .drainFinished,
        .tickRecordTaken, .shutdownRecorded,
    ]
    /// Empty since K2-2 commit 1b: every input is routed.
    static let deferred: [KeeperInputRoute: String] = [:]
}

/// Each `KeeperQuery` case by name, as `KeeperInputRoute` is for the inputs.
enum KeeperQueryRoute: String, CaseIterable, Sendable {
    case admitAction, admitClientEvent, admitServerInput, syncTurnNow, syncTurnTicket, settle
}

/// The queries K2-1 answers, and where each other one is routed. A tickless land's
/// `.admitServerInput` is refused on the core too (a precondition: its kick needs the keeper).
enum KeeperQueryRoutes {
    static let routed: Set<KeeperQueryRoute> = [.admitAction, .admitServerInput, .admitClientEvent, .syncTurnNow, .syncTurnTicket, .settle]
    static let deferred: [KeeperQueryRoute: String] = [:]
}

extension KeeperQuery {
    var route: KeeperQueryRoute {
        switch self {
        case .admitAction: .admitAction
        case .admitClientEvent: .admitClientEvent
        case .admitServerInput: .admitServerInput
        case .syncTurnNow: .syncTurnNow
        case .syncTurnTicket: .syncTurnTicket
        case .settle: .settle
        }
    }
}

/// Each `KeeperInput` case by name: `route` is exhaustive, so a new case needs a route here, and
/// the census checks that every route is routed or deferred.
enum KeeperInputRoute: String, CaseIterable, Sendable {
    case action, clientEvent, join, leave, tickDue, syncDue, freeze, resume, shutdown, awaitInitialized, syncStreamDraft, joinStepped, leaveStepped, actionResolved, actionJobReleased, awaitActionResult, initialize, initializeResolved, initializeRecorded, initializeDone, destroyHandlerResolved, recordTaken, inputDrainDue, drainFinished, startLand, freezeTimedOut, drainStart, afterFinalizeReturned, tickRecordTaken, shutdownRecorded
}

extension KeeperInput {
    /// The case's route, for `KeeperInputRoutes`.
    var route: KeeperInputRoute {
        switch self {
        case .action: .action
        case .clientEvent: .clientEvent
        case .join: .join
        case .leave: .leave
        case .tickDue: .tickDue
        case .syncDue: .syncDue
        case .freeze: .freeze
        case .resume: .resume
        case .shutdown: .shutdown
        case .awaitInitialized: .awaitInitialized
        case .syncStreamDraft: .syncStreamDraft
        case .joinStepped: .joinStepped
        case .leaveStepped: .leaveStepped
        case .actionResolved: .actionResolved
        case .actionJobReleased: .actionJobReleased
        case .awaitActionResult: .awaitActionResult
        case .initialize: .initialize
        case .initializeResolved: .initializeResolved
        case .initializeRecorded: .initializeRecorded
        case .initializeDone: .initializeDone
        case .destroyHandlerResolved: .destroyHandlerResolved
        case .recordTaken: .recordTaken
        case .inputDrainDue: .inputDrainDue
        case .drainFinished: .drainFinished
        case .startLand: .startLand
        case .freezeTimedOut: .freezeTimedOut
        case .drainStart: .drainStart
        case .afterFinalizeReturned: .afterFinalizeReturned
        case .tickRecordTaken: .tickRecordTaken
        case .shutdownRecorded: .shutdownRecorded
        }
    }

    /// The case's name.
    var routeName: String { route.rawValue }
}

/// Which of the join's awaits a `.joinStepped` result answers, with what its segment resumes
/// from (plan §4.3). The kick has no stage: its answer is the leave flow's own (`.leaveStepped`,
/// or its input-turn wait) under `.joinAfterKick`.
enum KeeperJoinStage<State: StateNodeProtocol>: Sendable {
    /// J2 resumes: CanJoin with the resolvers' outputs.
    case canJoinResolvers(KeeperJoinCall, syncsInTurn: Bool)
    /// J4 resumes: the OnJoin append.
    case onJoinResolvers(KeeperJoinDecided, LandKeeper<State>.OnJoinCapture, syncsInTurn: Bool)
}

/// Where a flow's answer goes when its last step ends (#700 K2-1, the reply plumbing): the
/// keeper's driver keeps this in its frame across the await; a core step carries it as a
/// value, out in the effect and back in the result input (a defunctionalized continuation,
/// as gen_server's `From`). Plain data, except the opaque `LandServices` payload a join's call
/// carries, which no step calls through; a request's `ResolverContext` or `LandContext` never
/// goes in.
enum KeeperContinuation: Sendable {
    /// The flow's own caller gets the answer (nil: nobody waits).
    case reply(InputID?)
    /// A join's kick of the player's old session, the entry with `kickedGeneration`: when the
    /// leave ends, J2c runs for `decided` (a leave that fails fails the join, with the leave's
    /// own error), then the join goes on.
    case joinAfterKick(KeeperJoinDecided, kickedGeneration: Epoch, caller: InputID?, syncsInTurn: Bool)
}

/// What a core step does when an input turn its flow waits for is recorded (#700 K2-1, the
/// reply plumbing): the step that records the turn answers it right after
/// `resumeInputTurnWaiters` resumes the keeper's waiters, with the same result. Plain values:
/// a join's call carries its services only as an opaque payload (`KeeperJoinCall`).
enum KeeperCoreInputWait: Sendable {
    /// J4's wait: the join's caller gets `outcome`. `decided` ends the attempt's reservation,
    /// as the keeper's driver does on every exit.
    case join(KeeperJoinOutcome, KeeperJoinDecided?, caller: InputID?)
    /// L2's wait: L3 runs, then the leave's continuation.
    case leave(KeeperContinuation)
    /// A tickless delivered action's wait: the intake's work count ends, then the caller gets
    /// the turn's outcome as `.completed`.
    case action(caller: InputID?)
    /// A tickless client event's wait: the work count ends, then the caller gets `.done` or the
    /// handler's error.
    case clientEvent(caller: InputID?)
    /// The resume's kick (the keeper's `startServerInputKick`): its work count ends once the
    /// turn applying the last held server input is recorded.
    case serverInputKick
}

/// An action job's start, as a value an effect carries (K2-2 plan, commit 0): what the keeper's
/// staged start captures. Not plain data: the box (the task handle, the caller's cancel and the
/// abandonment) is shared with the side's job table and the waiting caller, as it is today; the
/// model never stores it. The contexts are the resolvers' own, as a join's request carries them.
struct KeeperActionJobStart: Sendable {
    let sequence: Int64
    let box: KeeperActionJobTask
    let executors: [any AnyResolverExecutor]
    let resolverContext: ResolverContext
    let landContext: LandContext
}

/// The core's slot waits (K2-2 plan, commit 0): `awaitActionResult`'s callers, by sequence, and
/// the answers a slot fill made, which the step's end replies (`runCoreJobEffects`). Kept
/// empty on the keeper's side, where `slotWaiters` holds the continuations.
struct KeeperCoreSlotReplies: Sendable {
    var waits: [Int64: InputID?] = [:]
    var ready: [(caller: InputID?, Result<InputOutcome, any Error>)] = []
}

/// The core's input-turn waits, by input sequence, and the ones a drop of the pending inputs
/// failed, which the next step's end answers (`KeeperModel.answerDroppedCoreInputWaits`).
struct KeeperCoreInputReplies: Sendable {
    /// Whether this side is a core's (`KeeperSideStore`). On the keeper's own side the table
    /// stays empty: its driver awaits `inputTurnWaiters` instead.
    var onCore = false
    var waits: [Int64: KeeperCoreInputWait] = [:]
    var dropped: [KeeperCoreInputWait] = []
    /// The tick or sync step's read of `syncsInTurn`, carried from its input for that one step
    /// (a core's side has no keeper to ask the port with). Nil outside those steps, and always on
    /// the keeper's side, where `KeeperTurnSide.syncsInTurn` asks the port.
    var carriedSyncsInTurn: Bool?
    /// A core's job starts and releases a step made, which the step's end runs as effects
    /// (`runCoreJobEffects`), and its slot waits (K2-2 plan, commit 0). Empty on the keeper's
    /// side, where the start and the release are staged through the keeper reference.
    var jobStarts: [KeeperActionJobStart] = []
    var jobReleases: [(sequence: Int64, abandonment: ResolverAbandonment)] = []
    var slots = KeeperCoreSlotReplies()
    /// The routed inputs a core refused because they need the binding token (K2-2): each names
    /// the input and why. A core path that reaches one is a bug in K2-1; `actionTableViolations`
    /// reports each, so the differential's invariant fails on it.
    var refusals: [String] = []
    /// Tickless intakes held while frozen (the keeper's `debugWaitWhileFrozen`), in arrival
    /// order: the intake's own step is the barrier, so no freeze can settle between the wait
    /// and the intake (Review on #948). Each steps again when the land thaws or drains.
    var heldWhileFrozen: [KeeperHeldIntake] = []
}

/// A core's refusal of an input K2-1 doesn't route on the core (`KeeperCoreInputReplies.refusals`).
/// A tickless intake held at the freeze's barrier, with what its step needs to run again.
enum KeeperHeldIntake: Sendable {
    case action(ActionEnvelope, KeeperCaller, cancelled: Bool, cancellation: ActionJobCallerCancellation?, caller: InputID?)
    case clientEvent(AnyClientEvent, KeeperCaller, caller: InputID?)
}

struct KeeperCoreRefusal: Error, Sendable {
    let kind: KeeperCoreRefusalReason
    /// The refusal's message, as `refusals` records it.
    var reason: String { kind.message }
}

/// Why a core refuses an input, one case per refused shape (K2-2 plan §3.2): the commit that
/// lifts a refusal deletes its case, and commit 4's totality check requires the enum to be
/// empty, so the cut-over can't wire while a refused shape is in place.
enum KeeperCoreRefusalReason: String, CaseIterable, Sendable {
    /// A join syncing in the turn: its admission reads the binding after up to three awaits.
    case joinSyncingInTurn
    /// Any input of a tickless land with a transport attached (except `.startLand`): the input
    /// turn's output phase reads the binding inside the drain.
    case ticklessLandWithTransport

    /// The message the refusal carries and `refusals` records.
    var message: String {
        switch self {
        case .joinSyncingInTurn: "a join syncing in the turn needs the binding token (K2-2)"
        case .ticklessLandWithTransport: "a tickless land with a transport needs the binding token (K2-2)"
        }
    }

    /// The K2-2 commit that lifts the refusal and deletes the case.
    var liftedIn: String {
        switch self {
        case .joinSyncingInTurn, .ticklessLandWithTransport: "K2-2 commit 3: the binding token"
        }
    }
}

/// The intakes answered at once, and the adapter's synchronous calls (plan §4.1).
enum KeeperQuery: Sendable {
    /// `enforcingLimits`: the entry's choice, as the keeper's two entries make it
    /// (`submitAction` enforces the job caps, `handleActionEnvelope` doesn't).
    case admitAction(ActionEnvelope, KeeperCaller, enforcingLimits: Bool, cancelled: Bool = false)
    case admitClientEvent(AnyClientEvent, KeeperCaller)
    case admitServerInput(any ServerInputPayload)
    /// The sync entries (K2-2 commit 3). Each carries its port and the owner's identity, the
    /// object the port's in-turn witness (`runsSyncPhaseInTurn(of:)`) is asked about: the keeper,
    /// or the facade (commit 4). Never a value read by the sender: each arm asks the witness at
    /// the keeper entry's point (K2-2 plan §9, #948 round 2). `bindSyncRequester` runs in the
    /// query's step.
    case syncTurnNow(port: any LandKeeperTransport, owner: any AnyObject & Sendable, reason: SyncTurnReason, ticket: SyncTurnTicket?)
    case syncTurnTicket(port: any LandKeeperTransport, owner: any AnyObject & Sendable)
    /// The settle's fence as its two values (`SettleFence` is nested in the generic keeper).
    case settle(port: any LandKeeperTransport, owner: any AnyObject & Sendable, generation: UInt64, deadline: ContinuousClock.Instant)
}

/// Each query's answer.
enum KeeperAnswer<State: StateNodeProtocol>: Sendable {
    case actionSubmission(Result<ActionSubmission, any Error>)
    /// A tick land's event was queued for its next tick: no value, as today (no caller reads a
    /// sequence; K2-2 plan, commit 2).
    case clientEventQueued(Result<Void, any Error>)
    case serverInput(ServerInputOutcome)
    case syncTurn(InTurnSyncResult)
    case syncTurnTicket(SyncTurnTicket?)
    case settle(LandKeeper<State>.SettleTurnOutcome)
}

/// The I/O a step asks for (plan §4.3): a case per flow, wrapping K1b-5's request. The
/// adopter's `perform` does the await off the actor and returns the result input.
enum KeeperEffect<State: StateNodeProtocol>: Sendable {
    /// A join's resolvers (`.runCanJoinResolvers` or `.runOnJoinResolvers`); `perform` returns
    /// `.joinStepped` with the stage and the caller.
    case join(LandKeeper<State>.JoinRequest, KeeperJoinStage<State>, caller: InputID?)
    /// A leave's OnLeave resolvers (`.runOnLeaveResolvers`); `perform` returns `.leaveStepped`
    /// with the request's capture and the continuation.
    case leave(LandKeeper<State>.LeaveRequest, KeeperContinuation)
    /// An action job's resolvers (A1's start): `perform` installs its task in the start's box,
    /// runs the resolvers, and returns `.actionResolved`.
    case actionJob(KeeperActionJobStart)
    /// A completed job whose resolvers were abandoned: `perform` waits for them to end and
    /// returns `.actionJobReleased`.
    case actionJobRelease(sequence: Int64, ResolverAbandonment)
    /// OnInitialize's resolvers (`.runResolvers`): `perform` runs them and returns
    /// `.initializeResolved` with the cancellation of its own task.
    case initializeResolvers(LandKeeper<State>.InitializeResolving)
    /// The initialize record's submission, awaited off the core: `perform` returns
    /// `.initializeRecorded`.
    case initializeRecord(submission: RecorderSubmission?)
    /// A destroy handler's resolvers (`.runDestroyResolvers`): `perform` runs them without a
    /// deadline and returns `.destroyHandlerResolved` with the step (M8).
    case destroyResolvers(LandKeeper<State>.DestroyHandlerStep)
    /// AfterFinalize (`.runAfterFinalize`), in the scope its step opened with the side's drop
    /// counter (M9): `perform` runs the handler, closes the scope, returns `.afterFinalizeReturned`.
    case afterFinalize(LandKeeper<State>.AfterFinalizeStep, scoped: LandContext, scope: StepScope)
    /// `onLandDestroyed` on the port the step read, `transport ?? boundSyncRequester` (M10):
    /// `perform` returns `.drainFinished`.
    case notifyTransport(port: (any LandKeeperTransport)?)
    /// A tick land's tick record, awaited off the core (the tick-record hold): `perform` returns
    /// `.tickRecordTaken`.
    case awaitTickRecord(submission: RecorderSubmission?, tickId: Int64)
    /// The stop's shutdown turn record: `perform` returns `.shutdownRecorded`.
    case shutdownRecord(submission: RecorderSubmission?)
    /// A tickless input turn's record submission, awaited off the core; its applied inputs and
    /// their results come back in `.recordTaken` (K2-2 plan, item 15). The results are plain: a
    /// failure is its ID, owned meanwhile by the model's `inFlightRecordResults`.
    case awaitRecordTaken(submission: RecorderSubmission?, applied: [LandKeeper<State>.PendingItem], results: [Int64: InputResult], endsTickWork: Bool)
}

/// What a step leaves for the adopter's flush (plan §4.4, §4.5): record drafts, and the writes
/// to the binding token and the services table.
enum KeeperOutput: Sendable {
    case record(ReevaluationTickRecord, endsTurn: Bool)
    /// The initialization's `.startLoops`: the owner configures its loops, then sends
    /// `.initializeDone` with the two flags (K2-2 commit 1a). `epoch`: the `loopEpoch` its loop
    /// Tasks capture (K2-2 commit 1b, M5).
    case startLoops(epoch: UInt64)
    case bindTransport
    case services(PlayerID, Epoch, LandServices?)
    /// A sync folded into the tick due next (`.syncDue`): the driver keeps it, as the keeper's
    /// `pendingFold`, and passes it back on that tick's `.tickDue`.
    case fold(PendingFold)
    /// A freeze drops the fold the driver keeps (the keeper's `pendingFold = nil`, #232): the
    /// next sync iteration folds again.
    case dropFold
    /// The drain finished (M10): the owner sets the released stand-in, then `setTransport(nil)`.
    case detachTransport
    /// The drain's flag is set (M7): the owner holds `.drainStart`, cancels its loops, then
    /// sends `.drainStart`.
    case drainStarting
    /// A land failure's teardown (M7, the keeper's `runFailureTeardown`): the owner holds
    /// `.landFailedTeardown`, calls `landDidFail` on the port, then starts the drain.
    case failureTeardown(LandFailure, port: (any LandKeeperTransport)?)
}

/// Each `sendAndWait` entry's answer, and its failure as any error a caller gets today: a join
/// answers `.join` with its own result, a leave `.done` or its error.
enum KeeperReply<State: StateNodeProtocol>: Sendable {
    case join(Result<LandKeeper<State>.JoinOutcome, any Error>)
    /// A tickless action's submission: a job's `.pending`, or the input turn's `.completed`.
    case action(Result<ActionSubmission, any Error>)
    case input(Result<InputOutcome, any Error>)
    /// `.freeze`'s answer: whether the in-flight work finished with its generation in effect.
    case frozen(Bool)
    case done
}

extension KeeperModel: TurnMachine {
    typealias Input = KeeperInput<State>
    typealias Effect = KeeperEffect<State>
    typealias Output = KeeperOutput
    typealias Key = KeeperKey
    typealias Reply = KeeperReply<State>
    typealias Query = KeeperQuery
    typealias Answer = KeeperAnswer<State>
    typealias Behavior = KeeperBehavior<State>
    typealias BarrierKey = KeeperBarrierKey
    typealias BarrierPayload = KeeperBarrierPayload

    /// The resume, the teardown and the initialization's two owner sends are `.control`: a closed
    /// or full queue must never refuse the input that opens the freeze's barriers, ends the land,
    /// or answers the initialization's waiters (Review on #948, on #966). The choice
    /// depends on the input alone, as `TurnMachine.inputPolicy` requires.
    func inputPolicy(for input: KeeperInput<State>) -> InputPolicy<KeeperKey> {
        switch input {
        case .resume, .shutdown, .drainStart, .drainFinished, .initialize, .initializeDone: .control
        default: .normal(waitsFor: nil, belongsTo: nil)
        }
    }

    mutating func handle(_ input: KeeperInput<State>, _ turn: inout Turn<KeeperModel<State>>) {
        let behavior = turn.behavior
        guard let store = behavior.sideStore else { preconditionFailure("K2-1: a core-driven keeper needs its side store") }
        if let kind = coreRefusal(behavior, hasTransport: store.withSide({ side in side.attachedTransport != nil }), input) {
            store.withSide { side in side.coreInputReplies.refusals.append("\(input.routeName): \(kind.message)") }
            if let caller = turn.input { turn.reply(to: caller, .failure(KeeperCoreRefusal(kind: kind))) }
            store.withSide { side in side.onInputSteppedForTesting?(input.routeName) }
            return
        }
        switch input {
        case let .tickDue(fold, foldStart, syncsInTurn, epoch):
            // A tick from a loop the drain or a restart replaced: no step, no work (M5).
            if let epoch, epoch != loopEpoch { break }
            if behavior.isTickless {
                ticklessTickStep(behavior, store, &turn)
            } else {
                tickDueStep(behavior, store, &turn, fold: fold, foldStart: foldStart, syncsInTurn: syncsInTurn)
            }
        case let .recordTaken(applied, results, endsTickWork):
            // The keeper's drain after `submitTurnRecord`'s await: the callers resume (the
            // keeper's, then the core's waits), then the next batch. The carried results go back
            // for the resume, which takes each one, and leave the in-flight owners.
            for (sequence, result) in results {
                if case .failed(let id) = result { inFlightRecordResults.removeValue(forKey: id) }
                inputTurnResults[sequence] = result
            }
            let taken = Set(applied.map(\.sequence))
            inFlightRecordSequences.removeAll { taken.contains($0) }
            let waits = store.withSide { side in resumeInputTurnWaiters(behavior, &side, for: applied) }
            answerCoreInputWaits(behavior, store, &turn, waits)
            inputDrainStep(behavior, store, &turn, endsTickWork: endsTickWork)
        case .inputDrainDue:
            inputDrainStep(behavior, store, &turn, endsTickWork: false)
        case .startLand:
            _ = turn.start(.land)
        case let .action(envelope, who, cancelled, cancellation):
            let caller = turn.input
            actionStep(behavior, store, &turn, envelope, who, caller: caller, cancelled: cancelled, cancellation: cancellation)
        case let .clientEvent(event, who):
            let caller = turn.input
            clientEventStep(behavior, store, &turn, event, who, caller: caller)
        case let .join(call, syncsInTurn):
            let caller = turn.input
            joinDrive(behavior, store, &turn, call: call, caller: caller, syncsInTurn: syncsInTurn, decided: nil) { m, side, outputs in
                try m.joinBegin(behavior, &side, &outputs, call)
            }
        case let .joinStepped(stage, caller, result):
            joinStepped(behavior, store, &turn, stage, caller: caller, result)
        case let .leave(who):
            let caller = turn.input
            let request = step(behavior, store) { m, side, outputs in
                m.leaveBegin(behavior, &side, &outputs, playerID: who.playerID, clientID: who.clientID, sessionID: who.sessionID)
            }
            leaveDrive(behavior, store, &turn, request, .reply(caller))
        case let .leaveStepped(capture, continuation, result):
            switch result {
            case let .failure(error):
                step(behavior, store) { m, side, outputs in m.leaveResolversFailed(behavior, &side, &outputs, capture, error: error) }
                continueAfterLeave(behavior, store, &turn, .failure(error), continuation)
            case let .success(resolverOutputs):
                let request = step(behavior, store) { m, side, outputs in
                    // The resolvers' outputs, and the tick they finished at.
                    m.leaveAppend(behavior, &side, &outputs, capture, resolverOutputs: resolverOutputs, resolvedAtTick: m.lastCommittedTickId)
                }
                leaveDrive(behavior, store, &turn, request, continuation)
            }
        case let .syncDue(now, tickDeadline, foldPending, syncsInTurn, epoch):
            if let epoch, epoch != loopEpoch { break }
            if let fold = syncDueStep(behavior, store, now: now, tickDeadline: tickDeadline, foldPending: foldPending, syncsInTurn: syncsInTurn) {
                // `.land` is started by the owner at initialization (K2-1: the test harness's
                // init; K2-2: the core's init), never by a step. An emit before that is a bug:
                // loud in debug, and the core drops and counts it (`droppedOutputs`).
                assert(turn.isLive(.land) || !store.assertsOnUnstartedLandKey, "KeeperModel: a fold emitted before .land was started")
                turn.emit(.fold(fold), for: .land)
            }
        case let .actionResolved(sequence, resolved):
            // The worker's segment (A2), after the keeper's `.actionComplete` hold (the harness
            // holds the run instead).
            let drainWasScheduled = inputDrainScheduled
            step(behavior, store) { m, side, outputs in
                m.completeActionBody(behavior, &side, &outputs, sequence: sequence, resolved: resolved)
            }
            // A delivered tickless job kicks the drain (K2-2 plan §3.2): on the core that kick is
            // a queue entry, not the keeper's drain task (`scheduleInputDrain(_:_:)` stages none
            // on a core).
            if !drainWasScheduled, inputDrainScheduled { turn.queue(.inputDrainDue, behind: .land) }
        case let .actionJobReleased(sequence):
            step(behavior, store) { m, side, outputs in m.releaseCompletedActionJobBody(behavior, &side, &outputs, sequence) }
        case let .freeze(generation, timeout):
            freezeStep(&turn, generation: generation, timeout: timeout, assertsOnUnstartedLandKey: store.assertsOnUnstartedLandKey)
        case let .freezeTimedOut(generation, caller):
            // Only this caller's wait ends; the generation's other callers keep their own deadline.
            if var waits = coreBarrierWaits.freeze[generation], let index = waits.firstIndex(of: caller) {
                waits.remove(at: index)
                coreBarrierWaits.freeze[generation] = waits.isEmpty ? nil : waits
                turn.reply(to: caller, .success(.frozen(false)))
            }
            turn.end(.freezeWait(caller))
        case let .resume(generation):
            if let kick = resumeStep(behavior, &turn, generation: generation) {
                // The resume's kick wait (see `resumeStep`), on the side through the step frame.
                step(behavior, store) { _, side, _ in side.coreInputReplies.waits[kick] = .serverInputKick }
            }
            if let caller = turn.input { turn.reply(to: caller, .success(.done)) }
        // The initialization's flow (K2-2 commit 1a). Each step switches over every phase: the
        // one its request left behind runs, and every other is named. Only this flow's own
        // effects and queue send these inputs, so another phase is a broken flow, not a race.
        // Since commit 1b a drain can start during the flow (a land failure during OnInitialize's
        // resolvers): the phase stays `.resolving`, and `initializeResolved`'s body ends the
        // flow itself (`initializeEndedByDrain`, `.abandonedByDrain`, #952). A stop waits for the
        // flow's end (`stopAwaitsInitialization`), as `forceShutdown` waits in
        // `ensureInitialized`.
        case .initialize:
            // The keeper's `performInitialization`, its first segment.
            switch initializationPhase {
            case .notStarted:
                let request = step(behavior, store) { m, side, outputs in m.initializeBegin(behavior, &side, &outputs) }
                initializeDrive(behavior, store, &turn, request)
            case .replaying, .resolving, .recording, .finishing, .startingLoops, .done, .failed, .abandonedByDrain:
                preconditionFailure("the initialization runs once: .initialize in phase \(initializationPhase)")
            }
        case let .initializeResolved(resolving, result, initializationTaskCancelled):
            switch initializationPhase {
            case let .resolving(sequence) where sequence == resolving.sequence:
                let request = step(behavior, store) { m, side, outputs in
                    m.initializeResolved(behavior, &side, &outputs, resolving, result, initializationTaskCancelled: initializationTaskCancelled)
                }
                initializeDrive(behavior, store, &turn, request)
            case .resolving, .notStarted, .replaying, .recording, .finishing, .startingLoops, .done, .failed, .abandonedByDrain:
                preconditionFailure("OnInitialize's resolvers ended in phase \(initializationPhase) (sequence \(resolving.sequence))")
            }
        case .initializeRecorded:
            switch initializationPhase {
            case .recording:
                let request = step(behavior, store) { m, side, outputs in m.initializeRecorded(behavior, &side, &outputs) }
                initializeDrive(behavior, store, &turn, request)
            case .notStarted, .replaying, .resolving, .finishing, .startingLoops, .done, .failed, .abandonedByDrain:
                preconditionFailure("the initialize record was taken in phase \(initializationPhase)")
            }
        case let .initializeDone(tickLoopConfigured, syncLoopConfigured):
            switch initializationPhase {
            case .startingLoops:
                step(behavior, store) { m, side, outputs in
                    m.initializeDone(behavior, &side, &outputs, tickLoopConfigured: tickLoopConfigured, syncLoopConfigured: syncLoopConfigured)
                }
                answerInitializationWaits(behavior, store, &turn)
                beginStopAfterInitialization(behavior, store, &turn)
            case .notStarted, .replaying, .resolving, .recording, .finishing, .done, .failed, .abandonedByDrain:
                preconditionFailure("the owner's loops were configured in phase \(initializationPhase)")
            }
        case .awaitInitialized:
            // Open once the initialization ended. A failed one throws its failure, as the keeper's
            // `ensureInitialized` does to every entry (K2 §3.3.1); the facade's
            // `awaitInitialization` drops it with `try?`, as the keeper's does. A caller that
            // arrives before is answered by the step that ends it (`answerInitializationWaits`).
            guard let caller = turn.input else { break }
            if didInitialize {
                turn.reply(to: caller, initializationAnswer(behavior, store))
            } else {
                coreBarrierWaits.initialized.append(caller)
            }
        case let .syncStreamDraft(drafts, outsideTurn):
            // The keeper's `submitSyncStream` body: the drafts' factories run in the step, and one
            // that re-entered ends the land in this body, in place, as the keeper's does (no late
            // backstop: Review on #948).
            step(behavior, store) { m, side, outputs in
                let before = behavior.reentrySentinel.reentryViolations
                m.recordSyncStream(behavior, side, drafts, outsideTurn: outsideTurn)
                if behavior.reentrySentinel.reentryViolations != before { _ = m.applyReentryFailure(behavior, &side, &outputs) }
            }
        case let .awaitActionResult(sequence):
            let caller = turn.input
            let outcome = step(behavior, store) { m, side, _ in m.awaitActionResultBody(behavior, &side, sequence, caller: caller) }
            if let outcome, let caller { turn.reply(to: caller, .success(.input(outcome))) }
        // The destroy drain (K2-2 commit 1b, plan §13.2). Each result step switches over every
        // drain phase: only the drain's own effects send these inputs.
        case .drainStart:
            switch drainPhase {
            case .notStarted:
                // The owner held `.drainStart` and cancelled its loops (M7). No tick or sync
                // from before this step starts after it (`loopEpoch`). A started drain is a
                // requested one, whoever sent the start, so a later claimer joins it
                // (`startDrainIfIdle` keys on the request, as the keeper on `drainTask`).
                loopEpoch &+= 1
                drainRequested = true
                let request = step(behavior, store) { m, side, outputs in m.drainBegin(behavior, &side, &outputs) }
                drainDrive(behavior, store, &turn, request)
            case .waitingForTick, .destroyResolving, .afterFinalize, .notifyingTransport, .finished:
                preconditionFailure("the drain starts once: .drainStart in phase \(drainPhase)")
            }
        case let .destroyHandlerResolved(destroyStep, result):
            switch drainPhase {
            case let .destroyResolving(kind) where kind == destroyStep.kind.rawValue:
                let request = step(behavior, store) { m, side, outputs in
                    m.destroyHandlerResolved(behavior, &side, &outputs, destroyStep, result)
                }
                drainDrive(behavior, store, &turn, request)
            case .notStarted, .waitingForTick, .destroyResolving, .afterFinalize, .notifyingTransport, .finished:
                preconditionFailure("a destroy handler's resolvers ended in phase \(drainPhase) (kind \(destroyStep.kind.rawValue))")
            }
        case .afterFinalizeReturned:
            switch drainPhase {
            case .afterFinalize:
                let request = step(behavior, store) { m, side, outputs in m.drainAfterFinalize(behavior, &side, &outputs) }
                drainDrive(behavior, store, &turn, request)
            case .notStarted, .waitingForTick, .destroyResolving, .notifyingTransport, .finished:
                preconditionFailure("AfterFinalize returned in phase \(drainPhase)")
            }
        case .drainFinished:
            switch drainPhase {
            case .notifyingTransport:
                step(behavior, store) { m, side, outputs in m.drainFinished(behavior, &side, &outputs) }
                drainPhase = .finished
                // The owner's two calls follow this step, in order (M10): the released stand-in,
                // then `setTransport(nil)`.
                turn.emit(.detachTransport, for: .land)
                answerStopCallers(&turn)
            case .notStarted, .waitingForTick, .destroyResolving, .afterFinalize, .finished:
                preconditionFailure("onLandDestroyed returned in phase \(drainPhase)")
            }
        case let .tickRecordTaken(tickId):
            // The tick-record hold (plan §13.1): the tick's in-flight work ends here, once.
            precondition(ticksInFlight > 0, "the record of tick \(tickId) was taken with no tick in flight")
            endTick(behavior, store, &turn)
        case .shutdown:
            // The keeper's `forceShutdown`: `ensureInitialized` first, so a stop before the
            // initialization ended, done or failed, waits for it, whatever drain runs meanwhile.
            guard didInitialize else {
                if let caller = turn.input { coreBarrierWaits.stopsAwaitingInitialization.append(caller) }
                stopAwaitsInitialization = true
                break
            }
            admitStop(behavior, store, &turn, caller: turn.input)
        case .shutdownRecorded:
            switch stopPhase {
            case .recording:
                stopStartsDrain(behavior, store, &turn)
            case .notStarted, .waitingForTick, .awaitingShutdownTurn, .draining, .ended:
                preconditionFailure("the shutdown record was taken in phase \(stopPhase)")
            }
        default:
            // `KeeperInputRoutes.deferred` names where each of these is routed.
            preconditionFailure("K2-1: \(input.routeName) is routed in \(KeeperInputRoutes.deferred[input.route] ?? "an unnamed PR")")
        }
        endOfStep(behavior, store, &turn)
        store.withSide { side in side.onInputSteppedForTesting?(input.routeName) }
    }

    /// What every step does at its end, an input's (`handle`) and a query's (`answer`) alike
    /// (Review r1 on #969, MF2: a query step can fail the land too).
    /// - The barrier's held intakes, when this step thawed or drained the land.
    /// - A land failure's teardown, before the stop goes on: the keeper's `failLand` installs the
    ///   failure's drain in the failing segment, so a stop resumed by the same step joins it
    ///   (MF3: a tickless `[join, shutdown]` batch whose join fails the land).
    /// - The tickless stop, once its shutdown turn applied or a drain dropped it.
    /// - The barrier's leave waits whose leave ended (#953).
    /// - The core's waits on inputs this step dropped, the job starts, and the freeze replies.
    mutating func endOfStep(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        releaseCoreHeldIntakes(behavior, store, &turn)
        // To a fixpoint (Review on #983): a released join's J2c runs here, after the teardown
        // and the stop's resume, so whatever it stores that they read (a land failure, a leave
        // marker's end) is seen by another pass, not by a next step that may never come. The
        // loop ends: each release consumes its waits.
        repeat {
            startFailureTeardownIfNeeded(behavior, store, &turn)
            resumeStopAfterShutdownTurn(behavior, store, &turn)
        } while releaseEndedLeaveWaits(behavior, store, &turn)
        answerDroppedCoreInputWaits(behavior, store, &turn)
        runCoreJobEffects(store, &turn)
        answerCoreFreezeWaits(&turn)
    }

    /// `debugFreeze`'s decision as a step (K2-2 plan, commit 2): a released generation answers
    /// false; otherwise the land freezes, the driver's fold drops, and the caller gets true at
    /// once when no work is in flight, or waits for the step that ends the last of it
    /// (`answerCoreFreezeWaits`), its timeout (`.freezeTimedOut`) or the resume. The
    /// generation's re-check after each await (#129) is gone: the step reads it.
    mutating func freezeStep(
        _ turn: inout Turn<KeeperModel<State>>,
        generation: UInt64,
        timeout: Duration,
        assertsOnUnstartedLandKey: Bool
    ) {
        let caller = turn.input
        guard generation > debugReleasedGeneration else {
            if let caller { turn.reply(to: caller, .success(.frozen(false))) }
            return
        }
        debugFrozen = true
        debugActiveGeneration = generation
        // As `.syncDue`'s fold: an output for `.land` before it started is dropped silently.
        assert(turn.isLive(.land) || !assertsOnUnstartedLandKey, "KeeperModel: a fold drop emitted before .land was started")
        turn.emit(.dropFold, for: .land)
        guard debugInFlightWork > 0 else {
            if let caller { turn.reply(to: caller, .success(.frozen(true))) }
            return
        }
        guard let caller else { return }
        // An expired budget with work in flight: `debugFreeze` returns false without waiting.
        guard timeout > .zero else {
            turn.reply(to: caller, .success(.frozen(false)))
            return
        }
        coreBarrierWaits.freeze[generation, default: []].append(caller)
        // The keeper numbers each drain wait (`debugFreeze`'s waiter ID): the same count here.
        debugNextWaiterID &+= 1
        // One timer per caller, as `debugFreeze` gives each call its own deadline.
        _ = turn.start(.freezeWait(caller))
        turn.timer(at: Self.freezeDeadline(turn.now, timeout), for: .freezeWait(caller), .freezeTimedOut(generation: generation, caller: caller))
    }

    /// `now + timeout`, saturating at the range's end (`TurnInstant`'s `+` wraps, and
    /// `Duration`'s components overflow `Int64` nanoseconds for a large timeout).
    static func freezeDeadline(_ now: TurnInstant, _ timeout: Duration) -> TurnInstant {
        let (seconds, attoseconds) = timeout.components
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return TurnInstant(nanoseconds: .max) }
        let (nanoseconds, overflow2) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
        guard !overflow2 else { return TurnInstant(nanoseconds: .max) }
        let (deadline, overflow3) = now.nanoseconds.addingReportingOverflow(nanoseconds)
        return TurnInstant(nanoseconds: overflow3 ? .max : deadline)
    }

    /// `debugResume` as a step: the generation is released; when it is the one in effect, the
    /// land thaws, its held server inputs are appended (a tickless land's drain is scheduled, as
    /// the keeper's kick does), and the barrier's waiters are answered: the held intakes go on,
    /// and the freeze's callers get false.
    /// Returns the sequence the resume's kick waits on, which the caller registers.
    @discardableResult
    mutating func resumeStep(
        _ behavior: KeeperBehavior<State>,
        _ turn: inout Turn<KeeperModel<State>>,
        generation: UInt64
    ) -> Int64? {
        debugReleasedGeneration = max(debugReleasedGeneration, generation)
        guard debugActiveGeneration == generation else { return nil }
        debugActiveGeneration = nil
        debugFrozen = false
        var kick: Int64?
        if !serverInputsHeldWhileFrozen.isEmpty {
            let last = serverInputsHeldWhileFrozen[serverInputsHeldWhileFrozen.count - 1].sequence
            pendingItems.append(contentsOf: serverInputsHeldWhileFrozen)
            serverInputsHeldWhileFrozen.removeAll()
            if behavior.isTickless {
                // The keeper's kick (`kickServerInputTurn`): a work count that ends once the turn
                // applying the last held input is recorded, so a freeze right after the resume
                // waits for it (Review on #948). On the core the kick's task is a wait on that
                // sequence, answered by the turn's step.
                debugBeginWork()
                kick = last
                if scheduleInputDrain() { turn.queue(.inputDrainDue, behind: .land) }
            }
        }
        // The held intakes go on at the handler's end (`releaseCoreHeldIntakes`).
        // `debugResume` wakes every drain waiter; each re-checks and returns false.
        let waits = coreBarrierWaits.freeze
        coreBarrierWaits.freeze.removeAll()
        for caller in waits.values.joined() {
            turn.reply(to: caller, .success(.frozen(false)))
            turn.end(.freezeWait(caller))
        }
        return kick
    }

    /// The keeper's `endDebugFreezeForShutdown` (plan §11.1, arm 2): as `resumeStep`, except
    /// that the server inputs held while frozen stay out of the queue, for the drain to drop.
    /// The held intakes go on at the handler's end (`releaseCoreHeldIntakes`), behind the
    /// shutdown item this step appends on a tickless land (P11-2's batch order).
    mutating func endDebugFreezeForShutdown(_ turn: inout Turn<KeeperModel<State>>) {
        guard let generation = debugActiveGeneration else { return }
        debugReleasedGeneration = max(debugReleasedGeneration, generation)
        debugActiveGeneration = nil
        debugFrozen = false
        let waits = coreBarrierWaits.freeze
        coreBarrierWaits.freeze.removeAll()
        for caller in waits.values.joined() {
            turn.reply(to: caller, .success(.frozen(false)))
            turn.end(.freezeWait(caller))
        }
    }

    /// The freeze callers whose wait a step ended: the in-flight work is 0 with their generation
    /// still in effect (the keeper's `debugEndWork` resumes its drain waiters at the same point).
    /// When the work reaches 0, `debugEndWork` wakes every drain waiter, and each re-checks:
    /// the generation in effect returns true, a stale one false (Review on #948: a stale
    /// generation's caller is answered here, not at its timeout).
    mutating func answerCoreFreezeWaits(_ turn: inout Turn<KeeperModel<State>>) {
        guard debugInFlightWork == 0, !coreBarrierWaits.freeze.isEmpty else { return }
        let waits = coreBarrierWaits.freeze
        coreBarrierWaits.freeze.removeAll()
        for (generation, callers) in waits.sorted(by: { $0.key < $1.key }) {
            let frozen = generation == debugActiveGeneration
            for caller in callers {
                turn.reply(to: caller, .success(.frozen(frozen)))
                turn.end(.freezeWait(caller))
            }
        }
    }

    /// The job lane's effects and replies a step left on the core's side (K2-2 plan, commit 0):
    /// each start as `.actionJob`, each release as `.actionJobRelease`, then the slot waits a
    /// fill answered, in the order the step made them.
    mutating func runCoreJobEffects(_ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        let (starts, releases, ready) = store.withSide { side in
            defer {
                side.coreInputReplies.jobStarts.removeAll()
                side.coreInputReplies.jobReleases.removeAll()
                side.coreInputReplies.slots.ready.removeAll()
            }
            return (side.coreInputReplies.jobStarts, side.coreInputReplies.jobReleases, side.coreInputReplies.slots.ready)
        }
        for start in starts { turn.run(.actionJob(start)) }
        for release in releases { turn.run(.actionJobRelease(sequence: release.sequence, release.abandonment)) }
        for (caller, outcome) in ready {
            if let caller { turn.reply(to: caller, .success(.input(outcome))) }
        }
    }

    mutating func answer(_ query: KeeperQuery, _ turn: inout Turn<KeeperModel<State>>) -> KeeperAnswer<State> {
        let behavior = turn.behavior
        guard let store = behavior.sideStore else { preconditionFailure("K2-1: a core-driven keeper needs its side store") }
        let answer = answerQuery(behavior, store, query)
        // A query step can fail the land (a refused `callOut` → `failLand`): its teardown, the
        // drop's failed waits and the rest of a step's end run here, as `handle`'s. A tick land's
        // job intake is this query's (`.admitAction`): its start runs here too.
        endOfStep(behavior, store, &turn)
        return answer
    }

    private mutating func answerQuery(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ query: KeeperQuery) -> KeeperAnswer<State> {
        switch query {
        case let .admitAction(envelope, caller, enforcingLimits, cancelled):
            // The keeper's `submit` on a tick land: the intake's segment, answered at once (the
            // append's ACK, or a job's `.pending`; jobs run on the core from K2-2).
            precondition(!behavior.isTickless, "K2-1: a tickless land's action is the .action input")
            let result = step(behavior, store) { m, side, outputs in
                Result {
                    try m.actionIntakeBody(behavior, &side, &outputs, envelope, playerID: caller.playerID, clientID: caller.clientID,
                                           sessionID: caller.sessionID ?? behavior.config.systemSessionID, enforcingLimits: enforcingLimits, isTickless: false,
                                           callerCancelled: cancelled)
                }
            }
            return .actionSubmission(result.map { request in
                guard case let .done(submission) = request else { preconditionFailure("K2-1: a tick land's intake doesn't wait") }
                return submission
            })
        case let .admitServerInput(input):
            // A tickless land's intake kicks its input turn through the keeper
            // (`kickServerInputTurn` stages `startServerInputKick`, and begins a work count the
            // kick ends), which a core's side has no keeper for. K2-2 routes it with the core's
            // drain (plan §16 item 19).
            // A precondition, not a named `KeeperCoreRefusal`: the query's answer
            // (`ServerInputOutcome`) can refuse, but `ServerInputRefusal` has no K2-1 reason.
            precondition(!behavior.isTickless, "K2-1: a tickless land's server input is routed in K2-2")
            // The driver's segment S1 (`submitServerInputErased`): the check, the sequence and
            // the append in one body.
            return .serverInput(step(behavior, store) { m, side, outputs in m.serverInputIntake(behavior, &side, &outputs, input) })
        case let .admitClientEvent(event, caller):
            // A tick land's event (the keeper's `handleClientEvent` with a tick handler): the
            // intake's segment C1, queued for the next tick. A tickless land's is `.clientEvent`.
            precondition(!behavior.isTickless, "a tickless land's event is the .clientEvent input")
            let result = step(behavior, store) { m, side, _ in
                Result {
                    let awaited = try m.clientEventIntake(behavior, &side, event, playerID: caller.playerID, clientID: caller.clientID,
                                                          sessionID: caller.sessionID ?? behavior.config.systemSessionID)
                    precondition(awaited == nil, "a tick land's event doesn't wait")
                }
            }
            return .clientEventQueued(result)
        case let .syncTurnTicket(port, owner):
            // The keeper's `syncTurnTicket(via:)`, in its order: a live land, not failed or
            // draining, then the port's witness for the owner, outside a body (the keeper's entry
            // reads it outside `withTurn`, and so does this arm, before its frame), then the
            // binding in the step. A refusal before the witness runs no body, as on the keeper.
            guard acceptsSyncTurnState(behavior, store), port.runsSyncPhaseInTurn(of: owner) else { return .syncTurnTicket(nil) }
            return .syncTurnTicket(step(behavior, store) { m, side, _ in
                guard m.bindSyncRequester(side, port) else { return nil }
                return m.syncBinding.current
            })
        case let .syncTurnNow(port, owner, reason, ticket):
            // The keeper's `syncTurnNow(via:reason:ticket:)`, in `acceptsSyncTurn`'s order: the
            // state's checks, then the witness outside a body, then the binding, the ticket and
            // one sync-only turn in the step. The witness's answer is carried into the step for
            // the body's own reads (`syncsInTurn`): the body's second witness call, which the
            // keeper makes inside `callOut`, is short-circuited on a core, a stated asymmetry
            // (the census's `carriedSyncsInTurn` row) that K2-2's binding token removes. On a
            // core no follow-up is pending to consume: the guard drops each one after its phase
            // (#938 r3), so `pendingSyncTurnAfterTurn` stays nil.
            let accepted = acceptsSyncTurnState(behavior, store) && port.runsSyncPhaseInTurn(of: owner)
            store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = accepted }
            defer { store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = nil } }
            return .syncTurn(step(behavior, store) { m, side, outputs in
                m.requestedSyncTurnsForTesting[reason, default: 0] += 1
                guard accepted, m.bindSyncRequester(side, port) else { return .skipped }
                if let ticket, !m.syncBinding.isCurrent(ticket) { return .skipped }
                assert(side.pendingSyncTurnAfterTurn == nil, "a core holds no pending follow-up")
                return KeeperModel<State>.syncOnlyTurnBody(&m, behavior, &side, &outputs, transport: port, joinSyncOnly: false)
            })
        case let .settle(port, owner, generation, deadline):
            let fence = LandKeeper<State>.SettleFence(generation: generation, deadline: deadline)
            // The keeper's `settleTurn(via:fence:)`: the body checks the land, the deadline and
            // the generation, and only then asks the witness, through `callOut`, so a re-entry
            // from it ends the land in this step (#948 round 2). `owner` stands in for the
            // keeper reference, which a core's side leaves empty: its staged closures must not
            // reach the source keeper.
            return .settle(step(behavior, store) { m, side, outputs in
                m.settleBody(behavior, &side, &outputs, port: port, fence: fence, owner: owner)
            })
        }
    }
}

extension KeeperModel {
    /// The keeper's `performInitialization` loop on the core (K2-2 commit 1a), one request at a
    /// time: an await becomes an effect whose result is the next input, and the finish, the
    /// keeper's turn of its own, is a second step in the same handler (`.finish`), never a
    /// queued input. The re-evaluation pair stays the keeper's (#612): a core keeper is live.
    mutating func initializeDrive(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>, _ request: LandKeeper<State>.InitializeRequest) {
        switch request {
        case .checkReplayHeader, .runReplayBeforeTickZero:
            preconditionFailure("K2-2: a re-evaluation keeper's initialization stays on the keeper (#612)")
        case let .runResolvers(resolving):
            turn.run(.initializeResolvers(resolving))
        case let .submitRecord(record):
            let (_, submission) = stepSubmitting(behavior, store) { m, _, outputs in
                m.stageRecorderSubmission(behavior, record, endsTurn: behavior.isTickless, outputs: &outputs)
            }
            turn.run(.initializeRecord(submission: submission))
        case .finish:
            // A step of its own, right after OnInitialize's, in this same handler: the step that
            // returned `.finish` has ended, so its late backstop has run (T11), and nothing queued
            // steps in between, as on the keeper, whose `.finish` follows in the same actor turn
            // (Review on #966). No queue, so no refusal to drop.
            switch initializationPhase {
            case .finishing:
                let next = step(behavior, store) { m, side, outputs in m.initializeFinish(behavior, &side, &outputs) }
                initializeDrive(behavior, store, &turn, next)
            case .notStarted, .replaying, .resolving, .recording, .startingLoops, .done, .failed, .abandonedByDrain:
                preconditionFailure("the initialization's finish in phase \(initializationPhase)")
            }
        case .startLoops:
            // The loops are the owner's until #762: it configures them with this epoch (their
            // Tasks carry it on every `.tickDue` and `.syncDue`), then sends `.initializeDone`.
            // `.land` is started before `.initialize` is sent, as for every other emit on it
            // (`.syncDue`, `freezeStep`).
            assert(turn.isLive(.land) || !store.assertsOnUnstartedLandKey, "KeeperModel: .startLoops emitted before .land was started")
            loopEpoch &+= 1
            turn.emit(.startLoops(epoch: loopEpoch), for: .land)
        case .done:
            answerInitializationWaits(behavior, store, &turn)
            // A failed initialization tears down in this step, as the keeper's staged task does
            // (`initializeFail`'s stage finds no keeper on the core).
            if initializationPhase == .failed { tearDownAfterFailedInitialization(behavior, store, &turn) }
            beginStopAfterInitialization(behavior, store, &turn)
        }
    }

    /// Maps one of the drain's requests (#944's `DrainRequest`) onto the core (plan §13.2), and
    /// sets the phase it leaves.
    mutating func drainDrive(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>, _ request: LandKeeper<State>.DrainRequest) {
        switch request {
        case .waitForTick:
            // `.tickRecordTaken` resumes the drain once no tick is in flight.
            drainPhase = .waitingForTick
        case let .runDestroyResolvers(destroyStep):
            drainPhase = .destroyResolving(kind: destroyStep.kind.rawValue)
            turn.run(.destroyResolvers(destroyStep))
        case let .runAfterFinalize(finalizeStep):
            drainPhase = .afterFinalize
            // The scope opens here, with the side's drop counter (M9); the effect closes it.
            let (scoped, scope) = store.withSide { side in
                side.openStepScope(finalizeStep.ctx, random: finalizeStep.random, droppingInto: side.sharedDestroyHandlerOutputsDropped)
            }
            turn.run(.afterFinalize(finalizeStep, scoped: scoped, scope: scope))
        case .notifyTransport:
            drainPhase = .notifyingTransport
            let port = store.withSide { side in side.attachedTransport ?? side.sharedBoundRequester.port }
            turn.run(.notifyTransport(port: port))
        }
    }

    /// The initialization ended (done or failed): its waiters are answered.
    mutating func answerInitializationWaits(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        let waiting = coreBarrierWaits.initialized
        coreBarrierWaits.initialized.removeAll()
        guard !waiting.isEmpty else { return }
        let answer = initializationAnswer(behavior, store)
        for caller in waiting { turn.reply(to: caller, answer) }
    }

    /// The initialization's answer to a waiter, once it ended: `.done`, or its failure thrown, as
    /// the keeper's `ensureInitialized` throws `LandInitializationError` to every caller (K2
    /// §3.3.1, Review on #966). The error is the side's, looked up by the model's ID, as the
    /// keeper's `failure(for:path:sequence:)` does.
    mutating func initializationAnswer(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore) -> Result<KeeperReply<State>, any Error> {
        guard let id = initializationFailure else { return .success(.done) }
        if let error = store.withSide({ side in side.failures[id] }) { return .failure(error) }
        return .failure(noteFailureMiss(behavior, id, path: .initialization, sequence: nil))
    }

    /// A stop that arrived during the initialization begins at its end, after the waiters
    /// (`answerInitializationWaits`) and, on a failure, after the teardown's drain start, which
    /// it then joins.
    mutating func beginStopAfterInitialization(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        guard stopAwaitsInitialization else { return }
        stopAwaitsInitialization = false
        let waiting = coreBarrierWaits.stopsAwaitingInitialization
        coreBarrierWaits.stopsAwaitingInitialization.removeAll()
        for caller in waiting { admitStop(behavior, store, &turn, caller: caller) }
        if waiting.isEmpty { admitStop(behavior, store, &turn, caller: nil) }
    }

    /// A stop after `ensureInitialized` (`forceShutdown`'s flight). A stop whose flight returned
    /// (`.ended`) is answered at once, as the keeper's finished `SingleFlight` returns (Review r1
    /// on #969, MF1, a late joiner after completion). Any other stop waits in `drained`: a stop
    /// in progress is joined, even when a drain that overtook it has finished (the keeper's
    /// second caller awaits the first's flight, which awaits its record; Review r2), and the
    /// first stop begins, whose arm 1 joins a drain already finished and is answered in the
    /// same step (`startDrainIfIdle`).
    mutating func admitStop(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>, caller: InputID?) {
        if stopPhase == .ended {
            if let caller { turn.reply(to: caller, .success(.done)) }
            return
        }
        if let caller { coreBarrierWaits.drained.append(caller) }
        guard stopPhase == .notStarted else { return }
        stopBegin(behavior, store, &turn)
    }

    /// `acceptsSyncTurn`'s first guard, read before a sync query's frame: a live land, not
    /// failed or draining.
    func acceptsSyncTurnState(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore) -> Bool {
        behavior.config.mode == .live && store.withSide { side in side.failure == nil && !side.isDraining }
    }
}

// MARK: - The refusals

extension KeeperModel {
    /// Why a core refuses `input` in K2-1, or nil. Each refused shape needs the binding token,
    /// which K2-2 adds: a body that reads `syncsInTurn` outside a tick or sync step would get
    /// false on a core's side (no keeper to ask the port with), while the keeper's path asks the
    /// port, so the two would diverge without a difference the differential could see.
    /// - A join syncing in the turn: its admission, the stale-join refusal and the consumed-join
    ///   notifications read the binding at the admission, after up to three awaits.
    /// - Any input of a tickless land with a transport attached: the input turn's output phase
    ///   reads it inside the drain.
    func coreRefusal(_ behavior: KeeperBehavior<State>, hasTransport: Bool, _ input: KeeperInput<State>) -> KeeperCoreRefusalReason? {
        if case .join(_, syncsInTurn: true) = input {
            return .joinSyncingInTurn
        }
        // `.startLand` starts the core's key and reads no binding.
        if case .startLand = input { return nil }
        if behavior.isTickless, hasTransport {
            return .ticklessLandWithTransport
        }
        return nil
    }
}

// MARK: - The steps

extension KeeperModel {
    /// One turn body in a core step, in the frame the keeper's `withTurn` runs (`KeeperTurnFrame`):
    /// the body borrows the model and the store's side; the flush and the late re-entry run
    /// after that borrow ends.
    mutating func step<R>(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ body: (inout KeeperModel<State>, inout KeeperTurnSide, inout TurnOutputs) -> R
    ) -> R {
        stepSubmitting(behavior, store, body).result
    }

    /// `step`, also returning the frame's last recorder submission (from any of its flushes), as
    /// the keeper's `withTurnSubmitting` does for the submission its caller awaits.
    mutating func stepSubmitting<R>(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ body: (inout KeeperModel<State>, inout KeeperTurnSide, inout TurnOutputs) -> R
    ) -> (result: R, submission: RecorderSubmission?) {
        // The frame's isolation is nil here statically (a synchronous model method the core
        // calls), so the step checks its executor once at entry: the flush below then runs on
        // the owner's executor, checked, not assumed. The keeper's frame is isolated to the
        // keeper statically and has no such check.
        store.preconditionOnOwner()
        var violationsBefore = 0
        var submission: RecorderSubmission?
        let result = KeeperTurnFrame.run(
            behavior.reentrySentinel,
            flush: { outputs in
                // A copy, flushed after the borrow ends: a staged action finds neither the model
                // nor the side borrowed (KeeperTurnFrame's rule), as `flushOutsideTurn` does.
                let side = store.withSide { $0 }
                side.flush(&outputs)
                submission = outputs.lastSubmission ?? submission
            },
            lateReentry: { violationsBefore = $0 }
        ) { outputs in
            store.withSide { side in body(&self, &side, &outputs) }
        }
        // The keeper's `applyLateReentry`, after the frame: the closures above can't both hold
        // the model.
        if var late = store.withSide({ side in applyLateReentry(behavior, &side, since: violationsBefore) }) {
            let side = store.withSide { $0 }
            side.flush(&late.outputs)
            KeeperModel<State>.noteLateReentry(behavior, late.applied)
        }
        return (result, submission)
    }

    /// A tick land's `.tickDue`: the driver's live tick (`runTick`) with the same segments, and
    /// the record's submission flushed in the step, where the keeper awaits it (plan §4.4: the
    /// recorder's serial sink keeps the order).
    mutating func tickDueStep(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>, fold: PendingFold?, foldStart: ContinuousClock.Instant?, syncsInTurn: Bool) {
        guard let handler = behavior.definition.lifetimeHandlers.tickHandler else {
            preconditionFailure("K2-1: a tickless land's tick is routed with the input drain")
        }
        guard tickAdmit() == .admitted else { return }
        store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = syncsInTurn }
        defer { store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = nil } }
        guard let tickId = store.withSide({ side in tickStart(side) }) else {
            store.withSide { side in debugEndWork(&side) }
            return
        }
        // `runTick` fires it right before the turn; `tickTurnBody` fires only "turn-end".
        store.withSide { side in side.probe?("turn-begin") }
        let output = step(behavior, store) { m, side, outputs in
            m.tickTurnBody(behavior, &side, &outputs, handler: handler, tickId: tickId,
                           transport: syncsInTurn ? side.attachedTransport : nil, fold: fold, foldStart: foldStart)
        }
        let (_, submission) = stepSubmitting(behavior, store) { m, _, outputs in
            m.stageRecorderSubmission(behavior, output.record, endsTurn: behavior.isTickless, outputs: &outputs)
        }
        // The tick-record hold (K2-2 commit 1b, plan §13.1): as `runTick` holds `ticksInFlight`
        // and the work count across `submitTurnRecord`'s await, a tick with a submission ends in
        // `.tickRecordTaken`'s step. Without one it ends here, in this step, as before.
        if let submission {
            turn.run(.awaitTickRecord(submission: submission, tickId: tickId))
        } else {
            endTick(behavior, store, &turn)
        }
    }

    /// A tick land's tick ends: its in-flight count, then its work (`runTick`'s two `defer`s, in
    /// their order), then the waits that read either: the drain's `.waitForTick` and the freeze.
    mutating func endTick(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        let idle = tickEnd()
        store.withSide { side in debugEndWork(&side) }
        // Plan §13.1's order: the freeze's work wait is answered at the count's zero, before the
        // drain or the stop goes on in this step (Review r1 on #969).
        answerCoreFreezeWaits(&turn)
        if idle, drainPhase == .waitingForTick {
            let request = step(behavior, store) { m, side, outputs in m.drainAfterTicks(behavior, &side, &outputs) }
            drainDrive(behavior, store, &turn, request)
        }
        if idle, stopPhase == .waitingForTick {
            stopAfterTicks(behavior, store, &turn)
        }
    }

    /// `runForceShutdown`'s first segment (plan §11.1, arms 1 and 2).
    mutating func stopBegin(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        let draining = store.withSide { side in side.isDraining }
        // Arm 1: no turn when the drain has started, the initialization failed (#104), or in
        // re-evaluation. The players are cleared and the drain runs or is joined.
        guard drainPhase == .notStarted, !draining, initializationFailure == nil, behavior.config.mode == .live else {
            step(behavior, store) { m, side, _ in
                m.players.removeAll()
                side.playerServices.removeAll()
                m.rejoinReservations.removeAll()
                m.dropPendingInputs(behavior, &side, reason: "forceShutdown")
            }
            stopStartsDrain(behavior, store, &turn)
            return
        }
        // Arm 2: the freeze ends; its held intakes re-enter behind the shutdown, at this step's
        // end (`releaseCoreHeldIntakes`), and the server inputs held while frozen stay out of
        // the queue for the drain to drop.
        endDebugFreezeForShutdown(&turn)
        if behavior.definition.lifetimeHandlers.tickHandler != nil {
            shutdownRequested = true
            store.withSide { side in side.probe?("shutdown-stop-gate") }
            if ticksInFlight > 0 {
                stopPhase = .waitingForTick
            } else {
                stopAfterTicks(behavior, store, &turn)
            }
        } else {
            step(behavior, store) { m, side, _ in
                let sequence = m.sequence.take()
                m.pendingItems.append(.shutdown(PendingShutdownItem(sequence: sequence, resolvedAtTick: m.lastCommittedTickId)))
                side.probe?("shutdown-queued")
            }
            // The input turn that applies the item resumes the stop (`resumeStopAfterShutdownTurn`
            // at the handler's end), or a drain that dropped the item, which the stop joins.
            stopPhase = .awaitingShutdownTurn
            if scheduleInputDrain() { _ = turn.queue(.inputDrainDue, behind: .land) }
        }
    }

    /// A tickless land's stop, at the end of any step: the shutdown item's input turn applied
    /// (`completeShutdownTurn` set `shutdownTurnApplied`), or a drain that started dropped it.
    /// The keeper's `shutdownTurnWaiters`, as model state read after each step instead of a
    /// continuation. The keeper's `.shutdownTurnApplied` window is the owner's held drain start
    /// here (the harness's `armedDrainStartGate`); the facade's own hold is commit 4's.
    mutating func resumeStopAfterShutdownTurn(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        guard stopPhase == .awaitingShutdownTurn, shutdownTurnApplied || drainPhase != .notStarted else { return }
        stopStartsDrain(behavior, store, &turn)
    }

    /// A tick land's stop once no tick is in flight: the shutdown turn between ticks, unless a
    /// drain started during the wait, which is joined instead.
    mutating func stopAfterTicks(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        let draining = store.withSide { side in side.isDraining }
        guard drainPhase == .notStarted, !draining else {
            stopStartsDrain(behavior, store, &turn)
            return
        }
        let record = step(behavior, store) { m, side, outputs in m.shutdownTurnBetweenTicksBody(behavior, &side, &outputs) }
        guard let record else {
            stopStartsDrain(behavior, store, &turn)
            return
        }
        let (_, submission) = stepSubmitting(behavior, store) { m, _, outputs in
            m.stageRecorderSubmission(behavior, record, endsTurn: false, outputs: &outputs)
        }
        if let submission {
            stopPhase = .recording
            turn.run(.shutdownRecord(submission: submission))
        } else {
            stopStartsDrain(behavior, store, &turn)
        }
    }

    /// `shutdownIfIdle(cause: .forceShutdown)` on the core: joins a started drain, or, on an
    /// empty land, sets the drain flag in this step, releases the held inputs, ends the leaves in
    /// flight and the action jobs, and asks the owner to start the drain (M7). Callers wait in
    /// `coreBarrierWaits.drained`.
    mutating func stopStartsDrain(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        stopPhase = .draining
        startDrainIfIdle(behavior, store, &turn, cause: .forceShutdown)
    }

    /// The failed initialization's teardown (`tearDownAfterFailedInitialization`), in the step
    /// that failed it, on the core (plan §13.2): the players are cleared, the pending inputs
    /// dropped, and the drain starts.
    mutating func tearDownAfterFailedInitialization(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        step(behavior, store) { m, side, _ in
            m.players.removeAll()
            side.playerServices.removeAll()
            m.rejoinReservations.removeAll()
            m.dropPendingInputs(behavior, &side, reason: "initialization failed")
        }
        startDrainIfIdle(behavior, store, &turn, cause: .initializationFailed)
    }

    /// `shutdownIfIdle(cause:)` on the core.
    mutating func startDrainIfIdle(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>, cause: LandDestructionCause) {
        // A drain in progress is joined: its `.drainFinished` answers the callers. Keyed on the
        // drain's request, as the keeper's on `drainTask`, not on `isDraining`: the shutdown turn
        // (`completeShutdownTurn`) sets the flag before any drain runs.
        guard !drainRequested else {
            // A drain that already finished answers its joiners now (MF1).
            if drainPhase == .finished { answerStopCallers(&turn) }
            return
        }
        // A stored land failure takes precedence over an ordinary drain, whoever claims one (a
        // stop admitted in the step that failed the land, such as OnInitialize's late re-entry):
        // the failure's teardown is the drain, and this caller joins it, as the keeper's stop
        // joins the drain `failLand` staged in the failing segment (Review r2 on #969, MF1).
        startFailureTeardownIfNeeded(behavior, store, &turn)
        guard !drainRequested else { return }
        guard players.isEmpty else {
            // As the keeper: `shutdownIfIdle` returns without a drain, and so does the stop.
            answerStopCallers(&turn)
            return
        }
        step(behavior, store) { m, side, _ in
            side.sharedDrainFlag.set(cause: cause)
            m.releaseHeldInputsForDrain(behavior, &side)
            m.endAllLeavesInFlight(&side)
            m.cancelAllActionJobs(behavior, &side)
        }
        // The owner holds `.drainStart`, cancels its loops, then sends `.drainStart` (M7).
        drainRequested = true
        turn.emit(.drainStarting, for: .land)
    }

    /// The drain's callers are answered; a stop that was draining has returned (`.ended`), so a
    /// later one is answered at once. A stop still before its drain (waiting for its tick, its
    /// shutdown turn or its record) isn't answered here: the keeper's `forceShutdown` awaits
    /// that step first, so its callers stay in `drained`, and the step that moves it on
    /// (`stopAfterTicks`, `resumeStopAfterShutdownTurn`, `.shutdownRecorded`) reaches
    /// `stopStartsDrain`, which joins the finished drain and answers them. In 1b no drain can
    /// finish under such a stop (a land failure after the shutdown turn is refused by
    /// `setFailed`); commit 4's empty-room timer can start one during a tick stop's record
    /// (Review r3 on #969).
    mutating func answerStopCallers(_ turn: inout Turn<KeeperModel<State>>) {
        switch stopPhase {
        case .waitingForTick, .awaitingShutdownTurn, .recording: return
        case .notStarted, .draining, .ended: break
        }
        if stopPhase == .draining { stopPhase = .ended }
        let waiting = coreBarrierWaits.drained
        coreBarrierWaits.drained.removeAll()
        for caller in waiting { turn.reply(to: caller, .success(.done)) }
    }

    /// A land failure's teardown on the core (the keeper's `runFailureTeardown`, which
    /// `failLand` stages through `keeperReference`, empty on the core): at the end of the step
    /// that failed the land, the owner tells the port (`landDidFail`), then starts the drain
    /// (M7). An initialization that only failed (a `validate` throw or a resolver's
    /// `.failLand`) stores no land failure, so its own teardown
    /// (`tearDownAfterFailedInitialization`) claims an ordinary drain. One that also failed the
    /// land (OnInitialize's `validate` re-enters, then throws) takes the failure's teardown, as
    /// the keeper's `failLand` stages it as the drain in that segment; the drain still skips the
    /// destroy handlers on the initialization's failure (Review r3 on #969).
    mutating func startFailureTeardownIfNeeded(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        guard !drainRequested else { return }
        guard let (failure, port) = store.withSide({ side in side.failure.map { ($0, side.attachedTransport ?? side.sharedBoundRequester.port) } }) else { return }
        drainRequested = true
        turn.emit(.failureTeardown(failure, port: port), for: .land)
    }

    /// `.syncDue`: the driver's `runSync` with the same segments. Returns the fold the driver keeps
    /// when the sync folds into the tick due next; nil otherwise.
    mutating func syncDueStep(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        now: ContinuousClock.Instant,
        tickDeadline: ContinuousClock.Instant?,
        foldPending: Bool,
        syncsInTurn: Bool
    ) -> PendingFold? {
        // The only sync while frozen is the settle cycle run by the transport.
        guard !debugFrozen else { return nil }
        store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = syncsInTurn }
        defer { store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = nil } }
        if let handler = behavior.definition.lifetimeHandlers.syncHandler {
            store.withSide { side in runSyncHandler(behavior, side, handler) }
        }
        guard syncsInTurn, let transport = store.withSide({ side in side.attachedTransport }) else { return nil }
        // The coincident-sync rule, as in `runSync`: a tick due within the window takes the sync.
        if let deadline = tickDeadline, deadline - now <= behavior.coincidentSyncWindow {
            return foldSyncIntoTick(now: now, deadline: deadline, foldPending: foldPending)
        }
        // `runSyncOnlyTurn`: a failed land sends nothing more.
        guard store.withSide({ side in side.failure }) == nil else { return nil }
        step(behavior, store) { m, side, outputs in
            _ = KeeperModel<State>.syncOnlyTurnBody(&m, behavior, &side, &outputs, transport: transport, joinSyncOnly: false)
        }
        return nil
    }

    /// A tickless land's `.tickDue`: the driver's tickless branch of `runTick`. The tick counts as
    /// in-flight work until the drain it scheduled ends (`inputDrainStep`); a tick that finds a
    /// drain scheduled ends its work at once, as `runTick`'s defer does.
    mutating func ticklessTickStep(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        guard tickAdmit() == .admitted else { return }
        guard scheduleInputDrain() else {
            store.withSide { side in debugEndWork(&side) }
            return
        }
        inputDrainStep(behavior, store, &turn, endsTickWork: true)
    }

    /// One pass of the keeper's `runInputDrain` loop. A batch whose record holds entries is
    /// submitted, and its callers resume once the recorder took it (`.awaitRecordTaken`, then
    /// `.recordTaken`); a batch with an empty record resumes them in this step. With no batch
    /// left, the drain ends, and so does the tick's in-flight work when the drain was a tick's
    /// (`endsTickWork`; a drain a flow's wait scheduled has none, as the keeper's task).
    mutating func inputDrainStep(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>, endsTickWork: Bool) {
        while true {
            let batch = nextInputTurnBatch(limit: LandKeeper<State>.inputTurnBatchLimit)
            guard !batch.isEmpty else {
                // The keeper's drain end: the flag, then the probe. Its idle waiters are the
                // actor's (`inputDrainIdleWaitersForTesting`): a core-driven test waits on the
                // probe instead. The drain's `.inputDrain` hold is the keeper's alone until K2-2.
                endInputDrain()
                store.withSide { side in side.probe?("input-drain-end") }
                if endsTickWork { store.withSide { side in debugEndWork(&side) } }
                return
            }
            let mark = recorderSubmissionCount
            let preparedRecordBytes = LandKeeper<State>.prepareFallbackRecordBytes(behavior, batch)
            let outcome = step(behavior, store) { m, side, outputs in
                m.inputTurnBody(behavior, &side, &outputs, batch, removingFromQueue: true, preparedRecordBytes: preparedRecordBytes)
            }
            if !outcome.record.isEmpty {
                let (_, submission) = stepSubmitting(behavior, store) { m, _, outputs in
                    m.stageRecorderSubmission(behavior, outcome.record, endsTurn: behavior.isTickless, outputs: &outputs)
                }
                // The results ride the effect (item 15): out of `inputTurnResults`, with each held
                // failure owned by `inFlightRecordResults` until `.recordTaken` (K22-Q5).
                var results: [Int64: InputResult] = [:]
                for item in outcome.appliedItems {
                    guard let result = inputTurnResults.removeValue(forKey: item.sequence) else { continue }
                    if case .failed(let id) = result { inFlightRecordResults[id] = item.sequence }
                    results[item.sequence] = result
                }
                inFlightRecordSequences.append(contentsOf: outcome.appliedItems.map(\.sequence))
                turn.run(.awaitRecordTaken(submission: submission, applied: outcome.appliedItems, results: results, endsTickWork: endsTickWork))
                return
            }
            let waits = store.withSide { side in
                enqueueTicklessTurnEnd(behavior, side, since: mark)
                return resumeInputTurnWaiters(behavior, &side, for: outcome.appliedItems)
            }
            answerCoreInputWaits(behavior, store, &turn, waits)
        }
    }
}

// MARK: - The join and leave flows (plan §4.3, the reply plumbing)

extension KeeperModel {
    typealias KeeperSegment<R> = (inout KeeperModel<State>, inout KeeperTurnSide, inout TurnOutputs) throws -> R

    /// The keeper's `joinReportingAdmission` loop from `segment` on, in this step, until the
    /// join's next await (a `run`, or an input-turn wait) or its end. `decided`: the attempt's
    /// decision once J2 made it; its reservation and arrival token are ended on every exit
    /// (`finishJoin`), as the keeper's `defer` does. The `.join` hold is the keeper's test
    /// hold, not a step's.
    mutating func joinDrive(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        call: KeeperJoinCall,
        caller: InputID?,
        syncsInTurn: Bool,
        decided: KeeperJoinDecided?,
        _ segment: KeeperSegment<LandKeeper<State>.JoinRequest>
    ) {
        var decided = decided
        var next = step(behavior, store) { m, side, outputs in Result { try segment(&m, &side, &outputs) } }
        while true {
            let request: LandKeeper<State>.JoinRequest
            switch next {
            case let .failure(error):
                finishJoin(behavior, store, &turn, .failure(error), decided: decided, caller: caller)
                return
            case let .success(value):
                request = value
            }
            switch request {
            case .runCanJoinResolvers:
                turn.run(.join(request, .canJoinResolvers(call, syncsInTurn: syncsInTurn), caller: caller))
                return
            case let .holdThenKickCheck(made):
                // J2 took the reservation and the arrival in the segment that just ended.
                decided = made
                next = step(behavior, store) { m, side, outputs in Result { try m.joinKickCheck(behavior, &side, &outputs, made) } }
            case let .awaitLeave(made, leavingGeneration):
                // A join waiting for its player's leave in flight (#943) waits in the core's
                // barrier (#953) on the leave's end; the step that ends the leave releases it
                // (`releaseEndedLeaveWaits`), and J2c runs with the payload. The reservation and
                // the arrival token stay with the payload until the join ends.
                guard let caller else {
                    // Every core join is a call (`.join`'s step has its input's caller).
                    preconditionFailure("K2-2: a join that waits for a leave has a caller")
                }
                let payload = KeeperBarrierPayload.joinAfterLeave(made, leavingGeneration: leavingGeneration, syncsInTurn: syncsInTurn)
                switch turn.wait(caller, on: .leaveEnd(made.playerID, generation: leavingGeneration), holding: payload) {
                case .waiting:
                    store.withSide { side in side.probe?("join-awaits-leave") }
                case .refused(_, .cancelled):
                    // The keeper's `awaitLeaveEnd`: a join already cancelled never registers.
                    finishJoin(behavior, store, &turn, .failure(CancellationError()), decided: made, caller: caller)
                case .refused(_, .ended):
                    // Unreachable until the core is first ended: only `Turn.endAll()` makes `wait`
                    // refuse `.ended`, and the keeper's model calls none before commit 4's owner
                    // teardown. The keeper's answer stays (barrier plan §4.1, b7).
                    finishJoin(behavior, store, &turn, .failure(JoinError.landShuttingDown), decided: made, caller: caller)
                case .refused(_, .noWaiter):
                    // Its caller has no waiter (cancelled while the join's resolvers ran, or
                    // answered): no reply, the reservation and the token end.
                    finishJoin(behavior, store, &turn, .failure(CancellationError()), decided: made, caller: nil)
                case .expired:
                    preconditionFailure("K2-2: a join's leave wait has no timeout")
                }
                return
            case let .kick(made, oldClientID, oldSessionID, kickedGeneration):
                // The kick is the leave flow, nested, of the kicked entry alone: L1 in this
                // step; J2c runs when it ends.
                let leave = step(behavior, store) { m, side, outputs in
                    m.leaveBegin(behavior, &side, &outputs, playerID: made.playerID, clientID: oldClientID, sessionID: oldSessionID, entryGeneration: kickedGeneration)
                }
                leaveDrive(behavior, store, &turn, leave, .joinAfterKick(made, kickedGeneration: kickedGeneration, caller: caller, syncsInTurn: syncsInTurn))
                return
            case let .admit(made, joinSequence):
                // Between two segments, as on the keeper: the transport's admission is no body's.
                // A join syncing in the turn is refused on the core (`coreRefusal`), so no
                // transport admits here and `joinAfterAdmission` never schedules the keeper's drain.
                precondition(!syncsInTurn, "K2-1: a join syncing in the turn is refused on the core")
                let transport = syncsInTurn ? store.withSide({ side in side.attachedTransport }) : nil
                let admission = transport?.admitJoiningSession(playerID: made.playerID, clientID: made.call.clientID, sessionID: made.call.sessionID, joinSequence: joinSequence) ?? .notAdmitted
                guard let joinSequence else {
                    // J3b: no OnJoin input.
                    finishJoin(behavior, store, &turn, .success(KeeperJoinOutcome(decision: made.decision, admitted: admission.isAdmitted)), decided: decided, caller: caller)
                    return
                }
                next = .success(step(behavior, store) { m, side, outputs in
                    m.joinAfterAdmission(behavior, &side, &outputs, made, sequence: joinSequence, admission: admission)
                })
            case let .runOnJoinResolvers(made, capture, _, _):
                turn.run(.join(request, .onJoinResolvers(made, capture, syncsInTurn: syncsInTurn), caller: caller))
                return
            case let .awaitInputTurn(outcome, sequence):
                awaitCoreInputTurn(behavior, store, &turn, sequence, .join(outcome, decided, caller: caller))
                return
            case let .done(outcome):
                finishJoin(behavior, store, &turn, .success(outcome), decided: decided, caller: caller)
                return
            }
        }
    }

    /// The keeper's `debugWaitWhileFrozen` in the intake's step: while frozen and not draining,
    /// the intake is held (re-checked each time it steps, as the keeper's loop re-checks).
    func holdAtFreezeBarrier(_ store: KeeperSideStore, _ intake: KeeperHeldIntake) -> Bool {
        let frozen = debugFrozen
        return store.withSide { side in
            guard frozen, !side.isDraining else { return false }
            side.coreInputReplies.heldWhileFrozen.append(intake)
            side.probe?("input-held-frozen")
            return true
        }
    }

    /// The held intakes step again once the barrier opens: the resume thawed the land, or the
    /// land drains (the keeper's `debugResume` and `releaseHeldInputsForDrain` resume them).
    /// Run at the end of every step, in arrival order; each re-checks the barrier.
    mutating func releaseCoreHeldIntakes(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        let frozen = debugFrozen
        let held: [KeeperHeldIntake] = store.withSide { side in
            guard !side.coreInputReplies.heldWhileFrozen.isEmpty, !frozen || side.isDraining else { return [] }
            defer { side.coreInputReplies.heldWhileFrozen.removeAll() }
            return side.coreInputReplies.heldWhileFrozen
        }
        for intake in held {
            switch intake {
            case let .action(envelope, who, cancelled, cancellation, caller):
                actionStep(behavior, store, &turn, envelope, who, caller: caller, cancelled: cancelled, cancellation: cancellation, held: true)
            case let .clientEvent(event, who, caller):
                clientEventStep(behavior, store, &turn, event, who, caller: caller, held: true)
            }
        }
    }

    /// A tickless land's action (`.action`), as the keeper's `submit` runs it: the closed-land
    /// check, the freeze's barrier, the intake's segment, then the input turn's wait for a
    /// delivered action. `held`: the step runs again after the barrier held it, so the
    /// closed-land check, which the keeper makes once before its wait, is not made again.
    mutating func actionStep(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ envelope: ActionEnvelope,
        _ who: KeeperCaller,
        caller: InputID?,
        cancelled: Bool,
        cancellation: ActionJobCallerCancellation?,
        held: Bool = false
    ) {
        precondition(behavior.isTickless, "K2-1: a tick land's action is the .admitAction query")
        func reply(_ result: Result<ActionSubmission, any Error>, _ turn: inout Turn<KeeperModel<State>>) {
            if let caller { turn.reply(to: caller, .success(.action(result))) }
        }
        if !held {
            do {
                try store.withSide { side in try side.rejectIfLandClosed() }
            } catch {
                reply(.failure(error), &turn)
                return
            }
        }
        if holdAtFreezeBarrier(store, .action(envelope, who, cancelled: cancelled, cancellation: cancellation, caller: caller)) { return }
        // The keeper reads `Task.isCancelled` here, after `debugWaitWhileFrozen`: the send's read,
        // or the flag the caller's `onCancel` set since, synchronously (#948 round 3).
        let callerCancelled = cancelled || cancellation?.isSet == true
        let intake = step(behavior, store) { m, side, outputs in
            Result {
                try m.actionIntakeBody(behavior, &side, &outputs, envelope, playerID: who.playerID, clientID: who.clientID,
                                       sessionID: who.sessionID ?? behavior.config.systemSessionID, enforcingLimits: true, isTickless: true,
                                       callerCancelled: callerCancelled)
            }
        }
        switch intake {
        case let .failure(error):
            reply(.failure(error), &turn)
        case let .success(.done(submission)):
            reply(.success(submission), &turn)
        case let .success(.awaitInputTurn(sequence)):
            // `rejectIfAppendedInputDropped`: the land failed in the segment and the failure
            // dropped the input it appended.
            let failed = store.withSide { side in side.failure } != nil
            if failed, inputTurnResults[sequence] == nil, !pendingItems.contains(where: { $0.sequence == sequence }) {
                store.withSide { side in debugEndWork(&side) }
                reply(.failure(LandInputRejection.landClosed), &turn)
                return
            }
            awaitCoreInputTurn(behavior, store, &turn, sequence, .action(caller: caller))
        }
    }

    /// A tickless land's client event (`.clientEvent`), as the keeper's `handleClientEvent` runs
    /// it: the closed-land check, the intake's segment, then the input turn's wait. A tick land's
    /// event is the `.admitClientEvent` query, routed in K2-2.
    mutating func clientEventStep(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ event: AnyClientEvent,
        _ who: KeeperCaller,
        caller: InputID?,
        held: Bool = false
    ) {
        precondition(behavior.isTickless, "K2-1: a tick land's client event is the .admitClientEvent query")
        func reply(_ result: Result<Void, any Error>, _ turn: inout Turn<KeeperModel<State>>) {
            if let caller { turn.reply(to: caller, result.map { _ in KeeperReply<State>.done }) }
        }
        if !held {
            do {
                try store.withSide { side in try side.rejectIfLandClosed() }
            } catch {
                reply(.failure(error), &turn)
                return
            }
        }
        if holdAtFreezeBarrier(store, .clientEvent(event, who, caller: caller)) { return }
        let intake = step(behavior, store) { m, side, _ in
            Result {
                try m.clientEventIntake(behavior, &side, event, playerID: who.playerID, clientID: who.clientID,
                                        sessionID: who.sessionID ?? behavior.config.systemSessionID)
            }
        }
        switch intake {
        case let .failure(error):
            reply(.failure(error), &turn)
        case .success(nil):
            reply(.success(()), &turn)
        case let .success(sequence?):
            let failed = store.withSide { side in side.failure } != nil
            if failed, inputTurnResults[sequence] == nil, !pendingItems.contains(where: { $0.sequence == sequence }) {
                store.withSide { side in debugEndWork(&side) }
                reply(.failure(LandInputRejection.landClosed), &turn)
                return
            }
            awaitCoreInputTurn(behavior, store, &turn, sequence, .clientEvent(caller: caller))
        }
    }

    /// `.joinStepped`: the segment after the join's resolvers, as the keeper's loop runs it.
    mutating func joinStepped(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ stage: KeeperJoinStage<State>,
        caller: InputID?,
        _ result: Result<[String: HeldResolverOutput], any Error>
    ) {
        switch stage {
        case let .canJoinResolvers(call, syncsInTurn):
            switch result {
            case let .failure(error):
                // Before J2: no reservation yet.
                finishJoin(behavior, store, &turn, .failure(error), decided: nil, caller: caller)
            case let .success(resolverOutputs):
                joinDrive(behavior, store, &turn, call: call, caller: caller, syncsInTurn: syncsInTurn, decided: nil) { m, side, outputs in
                    // Rebuilt after the resolvers (only their outputs come back, plan §4.3); the
                    // keeper reuses J1's. The two read the model in two places only:
                    // `players["_pending"]` (CanJoin's placeholder ID: it differs only if a
                    // player of that literal ID joined or left meanwhile) and
                    // `lastCommittedTickId` for the emit closures, whose outputs CanJoin's scope
                    // drops (K2-E2). K2-2 carries J1's plain values in the stage if that
                    // placeholder lookup is kept.
                    let ctx = m.canJoinContext(behavior, side, call, resolverOutputs: resolverOutputs)
                    return try m.joinDecide(behavior, &side, &outputs, call, canJoinContext: ctx)
                }
            }
        case let .onJoinResolvers(decided, capture, syncsInTurn):
            switch result {
            case let .failure(error):
                // `runOnJoinResolvers`' catch: the entry's rollback, in its own segment.
                step(behavior, store) { m, side, outputs in m.onJoinResolversFailed(behavior, &side, &outputs, capture) }
                finishJoin(behavior, store, &turn, .failure(error), decided: decided, caller: caller)
            case let .success(resolverOutputs):
                joinDrive(behavior, store, &turn, call: decided.call, caller: caller, syncsInTurn: syncsInTurn, decided: decided) { m, side, outputs in
                    try m.joinAppend(behavior, &side, &outputs, decided, capture, resolverOutputs: resolverOutputs, resolvedAtTick: m.lastCommittedTickId)
                }
            }
        }
    }

    /// The keeper's `leaveEnds.release` (#943), at the end of any step: a join waiting on a leave
    /// whose marker is gone (its own end, `endLeaveInFlight`, or the drain's, `endAllLeavesInFlight`)
    /// or replaced by another generation's is released, and J2c runs with it, as the keeper's
    /// resumed join does after `awaitLeaveEnd`. Oldest first by `InputID`.
    /// Returns whether it released a wait.
    @discardableResult
    mutating func releaseEndedLeaveWaits(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) -> Bool {
        let inFlight = leavesInFlight
        let released = turn.release { key in
            switch key {
            case let .leaveEnd(player, generation): inFlight[player] != generation
            }
        }
        guard !released.isEmpty else { return false }
        for wait in released {
            switch wait.payload {
            case let .joinAfterLeave(decided, leavingGeneration, syncsInTurn):
                // Barrier plan §4.1's invariant: no step ends a player's leave and starts a newer
                // one, since the newer leave needs an entry only this released join can insert.
                // So a released wait's player has no marker left (b3 is equivalent by it).
                assert(inFlight[decided.playerID] == nil, "a newer leave of \(decided.playerID.rawValue) began in the step that ended generation \(leavingGeneration)")
                let cancelledWhileWaiting = wait.cancelled
                joinDrive(behavior, store, &turn, call: decided.call, caller: wait.caller, syncsInTurn: syncsInTurn, decided: decided) { m, side, outputs in
                    // The keeper's order after the wait: the drain first, then the cancel, then J2c.
                    guard !side.isDraining else { throw JoinError.landShuttingDown }
                    if cancelledWhileWaiting { throw CancellationError() }
                    return try m.joinAfterKick(behavior, &side, &outputs, decided, kickedGeneration: leavingGeneration)
                }
            }
        }
        return true
    }

    /// A barrier wait that ended without a release (#953): the join's reservation and arrival
    /// token end, as the keeper's `defer` ends them on every exit. A withdrawn caller has the
    /// core's `CancellationError` already; an ended core answers `landShuttingDown`.
    mutating func handleWaitEnded(_ ended: ReleasedWait<KeeperModel<State>>, _ why: WaitEnd, _ turn: inout Turn<KeeperModel<State>>) {
        let behavior = turn.behavior
        guard let store = behavior.sideStore else { preconditionFailure("K2-1: a core-driven keeper needs its side store") }
        switch ended.payload {
        case let .joinAfterLeave(decided, _, _):
            switch why {
            case .withdrawn, .answered:
                finishJoin(behavior, store, &turn, .failure(CancellationError()), decided: decided, caller: nil)
            case .ended:
                // Unreachable until the core is first ended (`Turn.endAll()`, commit 4's owner
                // teardown): no wait ends `.ended` before then. The keeper's answer stays (barrier
                // plan §4.1, b6).
                finishJoin(behavior, store, &turn, .failure(JoinError.landShuttingDown), decided: decided, caller: ended.caller)
            case .timedOut:
                preconditionFailure("K2-2: a join's leave wait has no timeout")
            }
        }
    }

    /// The join's end, success or failure: its reservation and its arrival token end (the
    /// keeper's `defer`, in a segment of its own), then the caller gets the join's own result.
    mutating func finishJoin(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ result: Result<KeeperJoinOutcome, any Error>,
        decided: KeeperJoinDecided?,
        caller: InputID?
    ) {
        if let decided {
            step(behavior, store) { m, _, _ in
                if let reservation = decided.reservation { m.endRejoinReservation(reservation, of: decided.playerID) }
                m.endJoinArrival(decided.arrival, of: decided.playerID)
            }
        }
        if let caller { turn.reply(to: caller, .success(.join(result))) }
    }

    /// The keeper's `driveLeave` from `request` on, in this step, until the leave's next await
    /// or its end, which goes to `continuation`.
    mutating func leaveDrive(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ request: LandKeeper<State>.LeaveRequest,
        _ continuation: KeeperContinuation
    ) {
        switch request {
        case .done:
            continueAfterLeave(behavior, store, &turn, .success(()), continuation)
        case .runOnLeaveResolvers:
            turn.run(.leave(request, continuation))
        case let .awaitInputTurn(sequence):
            awaitCoreInputTurn(behavior, store, &turn, sequence, .leave(continuation))
        }
    }

    /// A leave ended (`result`): its caller gets the answer, or, for a join's kick, J2c runs
    /// (the fence and the slot check) and the join goes on; a failed kick fails the join with
    /// the leave's own error.
    mutating func continueAfterLeave(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ result: Result<Void, any Error>,
        _ continuation: KeeperContinuation
    ) {
        switch continuation {
        case let .reply(caller):
            if let caller { turn.reply(to: caller, result.map { _ in KeeperReply<State>.done }) }
        case let .joinAfterKick(decided, kickedGeneration, caller, syncsInTurn):
            switch result {
            case let .failure(error):
                finishJoin(behavior, store, &turn, .failure(error), decided: decided, caller: caller)
            case .success:
                joinDrive(behavior, store, &turn, call: decided.call, caller: caller, syncsInTurn: syncsInTurn, decided: decided) { m, side, outputs in
                    try m.joinAfterKick(behavior, &side, &outputs, decided, kickedGeneration: kickedGeneration)
                }
            }
        }
    }

    /// The keeper's `awaitInputTurn` for a core's flow: an input neither pending nor applied
    /// answers `.none` now; otherwise the wait is kept on the side, answered when the input's
    /// turn is recorded, and the drain is scheduled (queued behind `.land`, as the keeper starts
    /// its task).
    mutating func awaitCoreInputTurn(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ sequence: Int64,
        _ wait: KeeperCoreInputWait
    ) {
        guard inputTurnResults[sequence] != nil || pendingItems.contains(where: { $0.sequence == sequence })
                || inFlightRecordSequences.contains(sequence) else {
            answerCoreInputWait(behavior, store, &turn, wait, .success(.none))
            return
        }
        store.withSide { side in side.coreInputReplies.waits[sequence] = wait }
        if scheduleInputDrain() { turn.queue(.inputDrainDue, behind: .land) }
    }

    /// Answers the core's waits `resumeInputTurnWaiters` returned, in batch order.
    mutating func answerCoreInputWaits(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ waits: [(KeeperCoreInputWait, Result<InputOutcome, any Error>)]
    ) {
        for (wait, result) in waits { answerCoreInputWait(behavior, store, &turn, wait, result) }
    }

    /// One wait's answer: J4's join ends with its outcome or the turn's error; a leave runs L3
    /// (skipped when the turn threw, as on the keeper) and goes to its continuation.
    mutating func answerCoreInputWait(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ wait: KeeperCoreInputWait,
        _ result: Result<InputOutcome, any Error>
    ) {
        switch wait {
        case let .join(outcome, decided, caller):
            finishJoin(behavior, store, &turn, result.map { _ in outcome }, decided: decided, caller: caller)
        case let .action(caller):
            // The keeper's `defer { debugEndWork() }` after the input turn, on success and on a throw.
            store.withSide { side in debugEndWork(&side) }
            if let caller { turn.reply(to: caller, .success(.action(result.map { .completed($0) }))) }
        case let .clientEvent(caller):
            store.withSide { side in debugEndWork(&side) }
            if let caller { turn.reply(to: caller, result.map { _ in KeeperReply<State>.done }) }
        case .serverInputKick:
            store.withSide { side in debugEndWork(&side) }
        case let .leave(continuation):
            switch result {
            case let .failure(error):
                continueAfterLeave(behavior, store, &turn, .failure(error), continuation)
            case .success:
                step(behavior, store) { m, side, outputs in m.scheduleDestroyIfNeeded(behavior, &side, &outputs) }
                continueAfterLeave(behavior, store, &turn, .success(()), continuation)
            }
        }
    }

    /// The waits a drop of the pending inputs failed (`dropPendingInputs`), answered
    /// `landClosed` at the end of the step that dropped them, as the keeper resumes its waiters
    /// there; an answer that drops more is answered in the same loop.
    mutating func answerDroppedCoreInputWaits(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>
    ) {
        while true {
            let dropped = store.withSide { side in
                defer { side.coreInputReplies.dropped.removeAll() }
                return side.coreInputReplies.dropped
            }
            guard !dropped.isEmpty else { return }
            for wait in dropped { answerCoreInputWait(behavior, store, &turn, wait, .failure(LandInputRejection.landClosed)) }
        }
    }
}
