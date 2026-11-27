// Sources/SwiftStateTree/Runtime/KeeperModel+Drivers.swift
//
// The drivers' synchronous glue as model segments (#700 K2-1, plan
// `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` §4.3). A driver (the tick loop's
// `runTick`, the tickless input drain) runs checks and counter writes around its turn bodies,
// between its awaits. They are model methods here so the keeper's driver and the core's steps
// call the same code (K2's condition 1). Each method is synchronous, and each one covers a
// stretch of a driver that has no await, so every segment boundary stays where an await is.
// No field changes home: every field these methods touch was already the model's.

import Foundation

/// Whether a tick may start: not while frozen.
enum KeeperTickAdmission: Equatable {
    case frozen
    /// Admitted: the tick counts as in-flight work (`debugInFlightWork`) until the driver's
    /// `debugEndWork`.
    case admitted
}

extension KeeperModel {
    // MARK: - The tick (`runTick`)

    /// A tick doesn't start while frozen (a body already running is drained by `debugFreeze`).
    /// Otherwise it begins one unit of in-flight work, which the caller ends with `debugEndWork`.
    mutating func tickAdmit() -> KeeperTickAdmission {
        guard !debugFrozen else { return .frozen }
        debugBeginWork()
        return .admitted
    }

    /// A tickless land's tick schedules the input drain: `true` when this call scheduled it,
    /// `false` when one is already scheduled. The drain clears the flag (`endInputDrain`).
    mutating func scheduleInputDrain() -> Bool {
        guard !inputDrainScheduled else { return false }
        inputDrainScheduled = true
        return true
    }

    /// Starts a tick: its ID, or nil when the land is draining or a forced shutdown waits for
    /// the tick in flight (#382). A started tick is in flight until `tickEnd`. Read in the same
    /// segment as the start, so no tick starts once the drain has (the drain waits for one in
    /// flight before it takes the pending inputs).
    mutating func tickStart(_ side: KeeperTurnSide) -> Int64? {
        guard !side.isDraining, !shutdownRequested else { return nil }
        ticksInFlight += 1
        defer { nextTickId += 1 }
        return nextTickId
    }

    /// Ends a started tick: `true` when no tick is in flight any more, and the caller wakes
    /// whoever waits for that.
    mutating func tickEnd() -> Bool {
        ticksInFlight -= 1
        return ticksInFlight == 0
    }

    // MARK: - The tickless input drain (`runInputDrain`)

    /// The next input turn's batch: at most `limit` ready inputs, in order.
    func nextInputTurnBatch(limit: Int) -> [PendingItem] {
        Array(readyPendingItemsInOrder().prefix(limit))
    }

    /// The drain found no ready input: a later tick schedules the next one.
    mutating func endInputDrain() {
        inputDrainScheduled = false
    }

    /// Resumes the callers of `batch` with their outcomes, after the turn was recorded: a
    /// response never leaves before its input is recorded. Returns the core's waits among them
    /// with their outcomes, for the step to answer next (#700 K2-1); none on the keeper's side.
    @discardableResult
    mutating func resumeInputTurnWaiters(_ behavior: KeeperBehavior<State>, _ side: inout KeeperTurnSide, for batch: [PendingItem]) -> [(KeeperCoreInputWait, Result<InputOutcome, any Error>)] {
        var coreWaits: [(KeeperCoreInputWait, Result<InputOutcome, any Error>)] = []
        for item in batch {
            // The result, and its error, are taken before the branch.
            let result: Result<InputOutcome, any Error> = inputTurnResults.removeValue(forKey: item.sequence)
                .map { taken(behavior, &side, $0, path: .inputTurn, sequence: item.sequence) } ?? .success(.none)
            if ticklessJobTurns.remove(item.sequence) != nil {
                // No waiter on the slot yet: held under a fresh ID.
                fillActionSlot(behavior, &side, item.sequence, with: result)
            } else if let waiter = side.inputTurnWaiters.removeValue(forKey: item.sequence) {
                waiter.resume(with: result)
            } else if let wait = side.coreInputReplies.waits.removeValue(forKey: item.sequence) {
                coreWaits.append((wait, result))
            }
        }
        // The keeper's label from before the move, so a violation reads as it did.
        checkActionTables(behavior, side, "resumeInputTurnWaiters(for:)")
        return coreWaits
    }

    // MARK: - The sync loop (`runSync`)

    /// The sync handler, read-only: it gets the state by value and a context keyed on the last
    /// committed tick. It isn't repeated from the record, so it draws from a copy of the land's
    /// generator, never written back, and its scope drops and counts its outputs (K2-E2).
    func runSyncHandler(_ behavior: KeeperBehavior<State>, _ side: KeeperTurnSide, _ handler: (State, LandContext) -> Void) {
        let ctx = makeContext(behavior, side,
            playerID: behavior.config.systemPlayerID,
            clientID: behavior.config.systemClientID,
            sessionID: behavior.config.systemSessionID,
            servicesOverride: LandServices(),
            tickId: lastCommittedTickId
        )
        let (scoped, scope) = side.openStepScope(ctx, random: detachedRandom(behavior), droppingInto: side.sharedReadOnlyHandlerOutputsDropped)
        defer { scope.close() }
        // Pass state as value (read-only) to emphasize that it should not be modified
        handler(state, scoped)
    }

    /// A sync that folds into the tick due within the coincident-sync window: counted once per
    /// tick turn it waits for, and the due sync marked. Returns the fold to keep until that tick
    /// turn (`takePendingFold`), or nil when one is already pending (`foldPending`). Keyed on the
    /// pending fold, not on `inTurnSyncDue`: a freeze drops the pending fold but keeps the due
    /// sync, and the fold after the resume counts.
    mutating func foldSyncIntoTick(now: ContinuousClock.Instant, deadline: ContinuousClock.Instant, foldPending: Bool) -> PendingFold? {
        var fold: PendingFold?
        if !foldPending {
            foldedSyncs += 1
            let overdue = deadline < now
            if overdue { overdueFoldedSyncs += 1 }
            fold = PendingFold(deadline: deadline, overdueAtFold: overdue)
        }
        inTurnSyncDue = true
        return fold
    }

    /// The sync-only turn's body (`runSyncOnlyTurn`), moved unchanged. Static, with the model as
    /// its first parameter, so the text is the old closure's: `m` is the hold.
    static func syncOnlyTurnBody(
        _ m: inout KeeperModel<State>,
        _ behavior: KeeperBehavior<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        transport: any LandKeeperTransport,
        joinSyncOnly: Bool
    ) -> InTurnSyncResult {
        // A failure a transport noted outside a turn ends the land first (#704), inside the
        // turn, so a callback from its gate close is refused: no phase runs. The mark comes
        // first, so a tickless land's turn end sees the failure's own submissions.
        let markBeforeNote = m.recorderSubmissionCount
        if m.applyPendingTransportFailure(behavior, &side, &outputs), let failure = side.failure {
            m.enqueueTicklessTurnEnd(behavior, side, since: markBeforeNote)
            return .landFailed(failure)
        }
        side.probe?("turn-begin")
        m.inTurnSyncTurnKind = .syncOnly
        defer { m.inTurnSyncTurnKind = .tick }
        let mark = m.recorderSubmissionCount
        // The sync phase, and the recording it gets, each through `callOut`: a refused
        // re-entry in either ends the land in that call, and the phase's answer is never read.
        var reentry: LandFailure?
        var result = InTurnSyncResult.skipped
        switch m.callOut(behavior, &side, &outputs, { m, side in m.inTurnSyncRecording(behavior, side) }) {
        case .refused(let refused):
            reentry = refused
        case .answered(let recording):
            switch m.callOut(behavior, &side, &outputs, { m, side in
                transport.runSyncPhaseInTurn(state: m.state, events: [], includeSync: true, recording: recording)
            }) {
            case .refused(let refused):
                reentry = refused
            case .answered(let output):
                // The transport's draft factories run here, in the body and outside any call
                // out: a factory that re-entered ends the land before the commit is applied.
                // The batch is recorded whole first, as a failing phase's is.
                let beforeRecording = behavior.reentrySentinel.reentryViolations
                m.recordSyncStream(behavior, side, output.syncStream)
                guard behavior.reentrySentinel.reentryViolations == beforeRecording else {
                    reentry = m.applyReentryFailure(behavior, &side, &outputs)
                    break
                }
                result = output.result
                m.applyInTurnSyncResult(
                    behavior,
                    &side,
                    &outputs,
                    output.result,
                    transport: transport,
                    joinSyncOnly: joinSyncOnly,
                    keepsEvents: output.keepsEvents,
                    joinsAwaitingSync: { m, side, outputs in
                        // `transportHasJoinsAwaitingSync`, one check per witness: whether the
                        // transport runs this keeper's phase, then whether joins wait.
                        switch m.callOut(behavior, &side, &outputs, { _, side in side.syncsInTurn(behavior) }) {
                        case .refused(let refused):
                            reentry = refused
                            return nil
                        case .answered(let runsPhase):
                            guard runsPhase, behavior.config.mode == .live, let attached = side.attachedTransport else { return false }
                            switch m.callOut(behavior, &side, &outputs, { _, _ in attached.hasJoinsAwaitingSync }) {
                            case .answered(let awaiting):
                                return awaiting
                            case .refused(let refused):
                                reentry = refused
                                return nil
                            }
                        }
                    }
                )
            }
        }
        // A refused call leaves the turn as a failed phase does: no sync is due any more.
        // Nothing of a refused phase is recorded or applied. A factory's re-entry keeps the
        // whole batch recorded, the drafts after the trip included, as a failing phase's
        // drafts are; it applies nothing.
        if reentry != nil { m.inTurnSyncDue = false }
        // The common tail, on every path. A tickless land's sync-only turn is its own turn
        // record (#327); a tick land's sync outputs stay with the current tick's.
        m.enqueueTicklessTurnEnd(behavior, side, since: mark)
        side.probe?("turn-end")
        if let reentry { return .landFailed(side.failure ?? reentry) }
        return result
    }
}
