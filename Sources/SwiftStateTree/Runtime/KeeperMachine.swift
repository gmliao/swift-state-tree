// The keeper's model as a turn machine (#700 K2-1, plan
// `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` §4). Not wired: the keeper doesn't
// drive a core yet (K2-2). K2-1's differential drives a test core with it and compares the result
// with the keeper's own path, through the very bodies and segments both call.

import Foundation
import SwiftStateTurns

/// The keys the machine's work belongs to (plan §4.1). The ids are today's: an entry is named by
/// its player and its generation (the `Epoch` in `entryGenerations`), a sync binding by its
/// `GenerationTable` ticket, a freeze by the generation `debugFreeze` takes.
enum KeeperKey: Hashable, Sendable {
    case land
    case initialization
    case entry(PlayerID, Epoch)
    case syncBinding(SyncTurnTicket)
    case freeze(UInt64)
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
    case action(ActionEnvelope, KeeperCaller)
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
    case awaitResume
    case syncStreamDraft([SyncStreamDraft])

    // Results of `run`.
    /// A join's resolvers returned: the stage names the segment that resumes, with what it
    /// carries; `caller` is the join's. No ticket: the only check is the segments' own (the
    /// drain, and `appendOnJoin`'s on `capture.entryGeneration`), as on the keeper.
    case joinStepped(KeeperJoinStage<State>, caller: InputID?, Result<[String: HeldResolverOutput], any Error>)
    /// A leave's OnLeave resolvers returned: L2 resumes with the capture L1 took, and the
    /// continuation says where the leave's answer goes. No ticket: L1 removed the entry, and L2
    /// re-reads only `isDraining`, as on the keeper.
    case leaveStepped(LandKeeper<State>.LeaveCapture, KeeperContinuation, Result<[String: HeldResolverOutput], any Error>)
    case actionResolved(sequence: Int64, Result<[String: HeldResolverOutput], any Error>)
    case initializeResolved(Result<[String: HeldResolverOutput], any Error>)
    case destroyHandlerResolved(index: Int, Result<[String: HeldResolverOutput], any Error>)
    /// A tickless input turn's record was taken by the recorder: its callers resume (K2-1 keeps
    /// their results in the model's `inputTurnResults`, as the keeper does; K2-2 moves them onto
    /// the effect and this input, plan §4.3).
    /// `endsTickWork`: the drain was a tick's, whose in-flight work ends with it.
    case recordTaken(applied: [LandKeeper<State>.PendingItem], endsTickWork: Bool)
    /// An input drain a flow's wait scheduled (the keeper's `scheduleInputDrain` task), queued
    /// behind `.land`.
    case inputDrainDue
    case drainFinished
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
/// as gen_server's `From`). Plain data: a join's call carries its services only as an opaque
/// payload no step calls through; a request's `ResolverContext` or `LandContext` never goes in.
enum KeeperContinuation: Sendable {
    /// The flow's own caller gets the answer (nil: nobody waits).
    case reply(InputID?)
    /// A join's kick of the player's old session: when the leave ends, J3 runs for `decided`
    /// (a leave that fails fails the join, with the leave's own error), then the join goes on.
    case joinAfterKick(KeeperJoinDecided, caller: InputID?, syncsInTurn: Bool)
}

/// What a core step does when an input turn its flow waits for is recorded (#700 K2-1, the
/// reply plumbing): the step that records the turn answers it right after
/// `resumeInputTurnWaiters` resumes the keeper's waiters, with the same result. Plain values:
/// a join's call carries its services only as an opaque payload (`KeeperJoinCall`).
enum KeeperCoreInputWait: Sendable {
    /// J4's wait: the join's caller gets `outcome`. `decided` ends the attempt's reservation,
    /// as the keeper's driver does on every exit.
    case join(KeeperJoinOutcome, KeeperJoinDecided, caller: InputID?)
    /// L2's wait: L3 runs, then the leave's continuation.
    case leave(KeeperContinuation)
}

/// The core's input-turn waits, by input sequence, and the ones a drop of the pending inputs
/// failed, which the next step's end answers (`KeeperModel.answerDroppedCoreInputWaits`).
struct KeeperCoreInputReplies: Sendable {
    /// Whether this side is a core's (`KeeperSideStore`). On the keeper's own side the table
    /// stays empty: its driver awaits `inputTurnWaiters` instead.
    var onCore = false
    var waits: [Int64: KeeperCoreInputWait] = [:]
    var dropped: [KeeperCoreInputWait] = []
}

/// The intakes answered at once, and the adapter's synchronous calls (plan §4.1).
enum KeeperQuery: Sendable {
    case admitAction(ActionEnvelope, KeeperCaller)
    case admitClientEvent(AnyClientEvent, KeeperCaller)
    case admitServerInput(any ServerInputPayload)
    case syncTurnNow(reason: SyncTurnReason, ticket: SyncTurnTicket?)
    case syncTurnTicket
    case settle
}

/// Each query's answer.
enum KeeperAnswer<State: StateNodeProtocol>: Sendable {
    case actionSubmission(Result<ActionSubmission, any Error>)
    case clientEventQueued(Result<Int64, any Error>)
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
    case action(sequence: Int64)
    case initialize
    case destroyHandler(index: Int)
    /// A tickless input turn's record submission, awaited off the core; its applied inputs come
    /// back in `.recordTaken`. K2-1 keeps their results in the model (`inputTurnResults`); K2-2
    /// carries them here instead (plan §4.3).
    case awaitRecordTaken(submission: RecorderSubmission?, applied: [LandKeeper<State>.PendingItem], endsTickWork: Bool)
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
}

/// Each `sendAndWait` entry's answer, and its failure as any error a caller gets today: a join
/// answers `.join` with its own result, a leave `.done` or its error.
enum KeeperReply<State: StateNodeProtocol>: Sendable {
    case join(Result<LandKeeper<State>.JoinOutcome, any Error>)
    case input(Result<InputOutcome, any Error>)
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

    mutating func handle(_ input: KeeperInput<State>, _ turn: inout Turn<KeeperModel<State>>) {
        let behavior = turn.behavior
        guard let store = behavior.sideStore else { preconditionFailure("K2-1: a core-driven keeper needs its side store") }
        switch input {
        case let .tickDue(fold, foldStart, syncsInTurn):
            if behavior.isTickless {
                ticklessTickStep(behavior, store, &turn)
            } else {
                tickDueStep(behavior, store, fold: fold, foldStart: foldStart, syncsInTurn: syncsInTurn)
            }
        case let .recordTaken(applied, endsTickWork):
            // The keeper's drain after `submitTurnRecord`'s await: the callers resume (the
            // keeper's, then the core's waits), then the next batch.
            let waits = store.withSide { side in resumeInputTurnWaiters(behavior, &side, for: applied) }
            answerCoreInputWaits(behavior, store, &turn, waits)
            inputDrainStep(behavior, store, &turn, endsTickWork: endsTickWork)
        case .inputDrainDue:
            inputDrainStep(behavior, store, &turn, endsTickWork: false)
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
        default:
            // The routes with a `run` come in the next commit (plan §4.3).
            preconditionFailure("K2-1: \(input) is not routed yet")
        }
        // A drop of the pending inputs in this step failed the core's waits on them.
        answerDroppedCoreInputWaits(behavior, store, &turn)
    }

    mutating func answer(_ query: KeeperQuery, _ turn: inout Turn<KeeperModel<State>>) -> KeeperAnswer<State> {
        let behavior = turn.behavior
        guard let store = behavior.sideStore else { preconditionFailure("K2-1: a core-driven keeper needs its side store") }
        switch query {
        case let .admitServerInput(input):
            // The driver's segment S1 (`submitServerInputErased`): the check, the sequence and
            // the append in one body.
            return .serverInput(step(behavior, store) { m, side, outputs in m.serverInputIntake(behavior, &side, &outputs, input) })
        default:
            preconditionFailure("K2-1: \(query) is not routed yet")
        }
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
                store.withSide { side in side.flush(&outputs) }
                submission = outputs.lastSubmission ?? submission
            },
            lateReentry: { violationsBefore = $0 }
        ) { outputs in
            store.withSide { side in body(&self, &side, &outputs) }
        }
        // The keeper's `applyLateReentry`, after the frame: the closures above can't both hold
        // the model.
        if var late = store.withSide({ side in applyLateReentry(behavior, &side, since: violationsBefore) }) {
            store.withSide { side in side.flush(&late.outputs) }
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
        // Declared first, so it runs last, as in `runTick`.
        defer { store.withSide { side in debugEndWork(&side) } }
        guard let tickId = store.withSide({ side in tickStart(side) }) else { return }
        // No drain waits on a core's ticks in K2-1; K2-2 makes the wait a reply.
        defer { _ = tickEnd() }
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
                endInputDrain()
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
                turn.run(.awaitRecordTaken(submission: submission, applied: outcome.appliedItems, endsTickWork: endsTickWork))
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
    /// decision once J2 made it; its reservation is ended on every exit (`finishJoin`), as the
    /// keeper's `defer` does. The `.join` hold is the keeper's test hold, not a step's.
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
                // J2 took the reservation in the segment that just ended.
                decided = made
                next = step(behavior, store) { m, side, outputs in Result { try m.joinKickCheck(behavior, &side, &outputs, made) } }
            case let .kick(made, oldClientID, oldSessionID):
                // The kick is the leave flow, nested: L1 in this step; J3 runs when it ends.
                let leave = step(behavior, store) { m, side, outputs in
                    m.leaveBegin(behavior, &side, &outputs, playerID: made.playerID, clientID: oldClientID, sessionID: oldSessionID)
                }
                leaveDrive(behavior, store, &turn, leave, .joinAfterKick(made, caller: caller, syncsInTurn: syncsInTurn))
                return
            case let .admit(made, joinSequence):
                // Between two segments, as on the keeper: the transport's admission is no body's.
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

    /// The join's end, success or failure: its reservation ends (the keeper's `defer`, in a
    /// segment of its own), then the caller gets the join's own result.
    mutating func finishJoin(
        _ behavior: KeeperBehavior<State>,
        _ store: KeeperSideStore,
        _ turn: inout Turn<KeeperModel<State>>,
        _ result: Result<KeeperJoinOutcome, any Error>,
        decided: KeeperJoinDecided?,
        caller: InputID?
    ) {
        if let decided, let reservation = decided.reservation {
            step(behavior, store) { m, _, _ in m.endRejoinReservation(reservation, of: decided.playerID) }
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

    /// A leave ended (`result`): its caller gets the answer, or, for a join's kick, J3 runs and
    /// the join goes on; a failed kick fails the join with the leave's own error.
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
        case let .joinAfterKick(decided, caller, syncsInTurn):
            switch result {
            case let .failure(error):
                finishJoin(behavior, store, &turn, .failure(error), decided: decided, caller: caller)
            case .success:
                joinDrive(behavior, store, &turn, call: decided.call, caller: caller, syncsInTurn: syncsInTurn, decided: decided) { m, side, outputs in
                    try m.joinInsert(behavior, &side, &outputs, decided)
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
        guard inputTurnResults[sequence] != nil || pendingItems.contains(where: { $0.sequence == sequence }) else {
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
