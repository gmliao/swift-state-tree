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

    var isEmpty: Bool { freeze.isEmpty && initialized.isEmpty }
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
    case tickDue(fold: PendingFold?, foldStart: ContinuousClock.Instant?, syncsInTurn: Bool)
    /// The sync loop is due, with the driver's reads made outside the step, as `runSync` makes
    /// them: `now`, the tick loop's next deadline (nil without a tick loop), whether a fold is
    /// already pending (the driver holds `pendingFold`), and `syncsInTurn` (see `.tickDue`).
    case syncDue(now: ContinuousClock.Instant, tickDeadline: ContinuousClock.Instant?, foldPending: Bool, syncsInTurn: Bool)
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
    case initializeResolved(Result<[String: HeldResolverOutput], any Error>)
    case destroyHandlerResolved(index: Int, Result<[String: HeldResolverOutput], any Error>)
    /// A tickless input turn's record was taken by the recorder: its callers resume with the
    /// results the effect carried (K2-2 plan, item 15).
    /// `endsTickWork`: the drain was a tick's, whose in-flight work ends with it.
    case recordTaken(applied: [LandKeeper<State>.PendingItem], results: [Int64: InputResult], endsTickWork: Bool)
    /// An input drain a flow's wait scheduled (the keeper's `scheduleInputDrain` task), queued
    /// behind `.land`.
    case inputDrainDue
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
    ]
    static let deferred: [KeeperInputRoute: String] = [
        .shutdown: "K2-2 commit 1: it ends in the destroy drain (after K2-1b)",
        .initializeResolved: "the segment PR for the initialization and the destroy drain, then K2-2 (plan §16 item 18)",
        .destroyHandlerResolved: "the segment PR for the initialization and the destroy drain, then K2-2 (plan §16 item 18)",
        .drainFinished: "the segment PR for the initialization and the destroy drain, then K2-2 (plan §16 item 18)",
    ]
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
    case action, clientEvent, join, leave, tickDue, syncDue, freeze, resume, shutdown, awaitInitialized, syncStreamDraft, joinStepped, leaveStepped, actionResolved, actionJobReleased, awaitActionResult, initializeResolved, destroyHandlerResolved, recordTaken, inputDrainDue, drainFinished, startLand, freezeTimedOut
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
        case .initializeResolved: .initializeResolved
        case .destroyHandlerResolved: .destroyHandlerResolved
        case .recordTaken: .recordTaken
        case .inputDrainDue: .inputDrainDue
        case .drainFinished: .drainFinished
        case .startLand: .startLand
        case .freezeTimedOut: .freezeTimedOut
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
    let reason: String
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
    case initialize
    case destroyHandler(index: Int)
    /// A tickless input turn's record submission, awaited off the core; its applied inputs and
    /// their results come back in `.recordTaken` (K2-2 plan, item 15). The results are plain: a
    /// failure is its ID, owned meanwhile by the model's `inFlightRecordResults`.
    case awaitRecordTaken(submission: RecorderSubmission?, applied: [LandKeeper<State>.PendingItem], results: [Int64: InputResult], endsTickWork: Bool)
}

/// What a step leaves for the adopter's flush (plan §4.4, §4.5): record drafts, and the writes
/// to the binding token and the services table.
enum KeeperOutput: Sendable {
    case record(ReevaluationTickRecord, endsTurn: Bool)
    case bindTransport
    case services(PlayerID, Epoch, LandServices?)
    /// A sync folded into the tick due next (`.syncDue`): the driver keeps it, as the keeper's
    /// `pendingFold`, and passes it back on that tick's `.tickDue`.
    case fold(PendingFold)
    /// A freeze drops the fold the driver keeps (the keeper's `pendingFold = nil`, #232): the
    /// next sync iteration folds again.
    case dropFold
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

    /// The resume and the teardown are `.control`: a closed or full queue must never refuse the
    /// input that opens the freeze's barriers or ends the land (Review on #948). The choice
    /// depends on the input alone, as `TurnMachine.inputPolicy` requires.
    func inputPolicy(for input: KeeperInput<State>) -> InputPolicy<KeeperKey> {
        switch input {
        case .resume, .shutdown, .drainFinished: .control
        default: .normal(waitsFor: nil, belongsTo: nil)
        }
    }

    mutating func handle(_ input: KeeperInput<State>, _ turn: inout Turn<KeeperModel<State>>) {
        let behavior = turn.behavior
        guard let store = behavior.sideStore else { preconditionFailure("K2-1: a core-driven keeper needs its side store") }
        if let reason = coreRefusal(behavior, hasTransport: store.withSide({ side in side.attachedTransport != nil }), input) {
            store.withSide { side in side.coreInputReplies.refusals.append("\(input.routeName): \(reason)") }
            if let caller = turn.input { turn.reply(to: caller, .failure(KeeperCoreRefusal(reason: reason))) }
            return
        }
        switch input {
        case let .tickDue(fold, foldStart, syncsInTurn):
            if behavior.isTickless {
                ticklessTickStep(behavior, store, &turn)
            } else {
                tickDueStep(behavior, store, fold: fold, foldStart: foldStart, syncsInTurn: syncsInTurn)
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
        case let .syncDue(now, tickDeadline, foldPending, syncsInTurn):
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
        case .awaitInitialized:
            // Open once OnInitialize ran; a failed initialization is not reported here, as
            // `awaitInitialization` doesn't. The closed case's answer is commit 1's (the step
            // that ends the initialization).
            guard let caller = turn.input else { break }
            if didInitialize {
                turn.reply(to: caller, .success(.done))
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
        default:
            // `KeeperInputRoutes.deferred` names where each of these is routed.
            preconditionFailure("K2-1: \(input.routeName) is routed in \(KeeperInputRoutes.deferred[input.route] ?? "an unnamed PR")")
        }
        // The barrier's held intakes, when this step thawed or drained the land.
        releaseCoreHeldIntakes(behavior, store, &turn)
        // A drop of the pending inputs in this step failed the core's waits on them.
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
        // A query step can fail the land (a refused `callOut` → `failLand` → the pending inputs'
        // drop), which fails the core's waits on them: answered here, as `handle` does. K2-1's
        // two routed queries are a tick land's, which has no input-turn waits, so none is
        // reachable yet; K2-2's tickless intakes are.
        releaseCoreHeldIntakes(behavior, store, &turn)
        answerDroppedCoreInputWaits(behavior, store, &turn)
        // A tick land's job intake is this query's (`.admitAction`): its start runs here.
        runCoreJobEffects(store, &turn)
        answerCoreFreezeWaits(&turn)
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
    func coreRefusal(_ behavior: KeeperBehavior<State>, hasTransport: Bool, _ input: KeeperInput<State>) -> String? {
        if case .join(_, syncsInTurn: true) = input {
            return "a join syncing in the turn needs the binding token (K2-2)"
        }
        // `.startLand` starts the core's key and reads no binding.
        if case .startLand = input { return nil }
        // A tick land's freeze answers from the work count, and the core doesn't yet hold the
        // tick's count across its record's submission, as the keeper does (Review on #948).
        if case .freeze = input, !behavior.isTickless {
            return "a tick land's freeze needs the tick record's hold (K2-2 commit 1)"
        }
        if behavior.isTickless, hasTransport {
            return "a tickless land with a transport needs the binding token (K2-2)"
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
    mutating func tickDueStep(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, fold: PendingFold?, foldStart: ContinuousClock.Instant?, syncsInTurn: Bool) {
        guard let handler = behavior.definition.lifetimeHandlers.tickHandler else {
            preconditionFailure("K2-1: a tickless land's tick is routed with the input drain")
        }
        guard tickAdmit() == .admitted else { return }
        store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = syncsInTurn }
        defer { store.withSide { side in side.coreInputReplies.carriedSyncsInTurn = nil } }
        // Declared first, so it runs last, as in `runTick`.
        defer { store.withSide { side in debugEndWork(&side) } }
        guard let tickId = store.withSide({ side in tickStart(side) }) else { return }
        // No drain waits on a core's ticks in K2-1; K2-2 makes the wait a reply.
        defer { _ = tickEnd() }
        // `runTick` fires it right before the turn; `tickTurnBody` fires only "turn-end".
        store.withSide { side in side.probe?("turn-begin") }
        let output = step(behavior, store) { m, side, outputs in
            m.tickTurnBody(behavior, &side, &outputs, handler: handler, tickId: tickId,
                           transport: syncsInTurn ? side.attachedTransport : nil, fold: fold, foldStart: foldStart)
        }
        step(behavior, store) { m, _, outputs in
            m.stageRecorderSubmission(behavior, output.record, endsTurn: behavior.isTickless, outputs: &outputs)
        }
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
