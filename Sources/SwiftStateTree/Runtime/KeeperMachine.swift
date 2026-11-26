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
    case tickDue(tickId: Int64, fold: PendingFold?, foldStart: ContinuousClock.Instant?)
    case syncDue
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
    case recordTaken(ticket: Int64, results: [Int64: Result<InputOutcome, any Error>])
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
    /// A tickless turn's results ride to the recorder's hand-off and come back in
    /// `.recordTaken` (plan §4.3).
    case awaitRecordTaken(ticket: Int64, results: [Int64: Result<InputOutcome, any Error>])
}

/// What a step leaves for the adopter's flush (plan §4.4, §4.5): record drafts, and the writes
/// to the binding token and the services table.
enum KeeperOutput: Sendable {
    case record(ReevaluationTickRecord, endsTurn: Bool)
    case bindTransport
    case services(PlayerID, Epoch, LandServices?)
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
        // Commit 2 routes each input to the segment the keeper's driver calls (plan §4.3).
        preconditionFailure("K2-1: \(input) is not routed yet")
    }

    mutating func answer(_ query: KeeperQuery, _ turn: inout Turn<KeeperModel<State>>) -> KeeperAnswer<State> {
        preconditionFailure("K2-1: \(query) is not routed yet")
    }
}
