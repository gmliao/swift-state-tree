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
    case join(LandKeeper<State>.JoinCall)
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
    case joinStepped(KeeperJoinStage, ticket: Epoch?, Result<[String: HeldResolverOutput], any Error>)
    case leaveStepped(ticket: Epoch, Result<[String: HeldResolverOutput], any Error>)
    case actionResolved(sequence: Int64, Result<[String: HeldResolverOutput], any Error>)
    case initializeResolved(Result<[String: HeldResolverOutput], any Error>)
    case destroyHandlerResolved(index: Int, Result<[String: HeldResolverOutput], any Error>)
    /// A tickless input turn's record was taken by the recorder: its callers resume (K2-1 keeps
    /// their results in the model's `inputTurnResults`, as the keeper does; K2-2 moves them onto
    /// the effect and this input, plan §4.3).
    case recordTaken(applied: [LandKeeper<State>.PendingItem])
    case drainFinished
}

/// Which of the join's awaits a `.joinStepped` result answers (plan §4.3).
enum KeeperJoinStage: Sendable {
    case canJoinResolvers
    case kick
    case onJoinResolvers
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
    case join(LandKeeper<State>.JoinRequest)
    case leave(LandKeeper<State>.LeaveRequest)
    case action(sequence: Int64)
    case initialize
    case destroyHandler(index: Int)
    /// A tickless input turn's record submission, awaited off the core; its applied inputs come
    /// back in `.recordTaken`. K2-1 keeps their results in the model (`inputTurnResults`); K2-2
    /// carries them here instead (plan §4.3).
    case awaitRecordTaken(submission: Task<Void, Never>?, applied: [LandKeeper<State>.PendingItem])
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

/// Each `sendAndWait` entry's answer, and its failure as any error a caller gets today.
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
        case let .recordTaken(applied):
            // The keeper's drain after `submitTurnRecord`'s await: the callers resume, then the
            // next batch.
            store.withSide { side in resumeInputTurnWaiters(behavior, &side, for: applied) }
            inputDrainStep(behavior, store, &turn)
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
    ) -> (result: R, submission: Task<Void, Never>?) {
        // The frame's isolation is nil here statically (a synchronous model method the core
        // calls), so the step checks its executor once at entry: the flush below then runs on
        // the owner's executor, checked, not assumed. The keeper's frame is isolated to the
        // keeper statically and has no such check.
        store.preconditionOnOwner()
        var violationsBefore = 0
        var submission: Task<Void, Never>?
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
        inputDrainStep(behavior, store, &turn)
    }

    /// One pass of the keeper's `runInputDrain` loop. A batch whose record holds entries is
    /// submitted, and its callers resume once the recorder took it (`.awaitRecordTaken`, then
    /// `.recordTaken`); a batch with an empty record resumes them in this step. With no batch
    /// left, the drain ends and so does the tick's in-flight work.
    mutating func inputDrainStep(_ behavior: KeeperBehavior<State>, _ store: KeeperSideStore, _ turn: inout Turn<KeeperModel<State>>) {
        while true {
            let batch = nextInputTurnBatch(limit: LandKeeper<State>.inputTurnBatchLimit)
            guard !batch.isEmpty else {
                endInputDrain()
                store.withSide { side in debugEndWork(&side) }
                return
            }
            let mark = recorderSubmissionCount
            let preparedRecordBytes = KeeperModel<State>.prepareFallbackRecordBytes(behavior, batch)
            let outcome = step(behavior, store) { m, side, outputs in
                m.inputTurnBody(behavior, &side, &outputs, batch, removingFromQueue: true, preparedRecordBytes: preparedRecordBytes)
            }
            if !outcome.record.isEmpty {
                let (_, submission) = stepSubmitting(behavior, store) { m, _, outputs in
                    m.stageRecorderSubmission(behavior, outcome.record, endsTurn: behavior.isTickless, outputs: &outputs)
                }
                turn.run(.awaitRecordTaken(submission: submission, applied: outcome.appliedItems))
                return
            }
            store.withSide { side in
                enqueueTicklessTurnEnd(behavior, side, since: mark)
                resumeInputTurnWaiters(behavior, &side, for: outcome.appliedItems)
            }
        }
    }
}
