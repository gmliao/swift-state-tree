import Foundation
import Logging
import SwiftStateTurns

/// One in-turn sync fold, reported when the tick turn that carries it starts (#232).
///
/// The sync loop folds into the next tick turn when that tick is due within
/// `coincidentWindow`. The keeper notes the tick deadline then, and measures the lateness when
/// the tick turn starts: the folded frame waits for that turn, so the lateness at the fold (the
/// tick has not run yet) would only be a lower bound.
public struct InTurnSyncFold: Sendable, Equatable {
    /// The tick's deadline had already passed when the sync loop folded (`deadline < now`).
    /// Mostly a race between a land's phase-locked tick and sync loops, not tick lateness.
    public let overdueAtFold: Bool
    /// The tick turn's start minus the deadline the sync folded on; negative when it started early.
    public let tickLateness: Duration
    /// The keeper's coincident-sync window: min(5 ms, tick / 4, sync / 4).
    public let coincidentWindow: Duration

    public init(overdueAtFold: Bool, tickLateness: Duration, coincidentWindow: Duration) {
        self.overdueAtFold = overdueAtFold
        self.tickLateness = tickLateness
        self.coincidentWindow = coincidentWindow
    }

    /// The tick turn started later than the coincident window allows (strict).
    public var isLate: Bool { tickLateness > coincidentWindow }
}

/// Protocol defining transport operations that LandKeeper needs.
///
/// This protocol allows LandKeeper to communicate with the transport layer
/// without directly depending on transport implementations. This maintains
/// the architectural separation where Core (LandKeeper) doesn't depend on
/// Transport layer, while Transport layer depends on Core.
///
/// A live keeper hands its output to the transport inside its turns (`runSyncPhaseInTurn`), so a
/// transport implements the in-turn requirements itself: `runsSyncPhaseInTurn(of:)`,
/// `runSyncPhaseInTurn` and `waitForWriterDrainForInTurnSync()` have no default (#546 L2d-3).
/// The other requirements' defaults are right for a transport that runs in turn but never
/// admits joins in its turn and doesn't profile folds.
public protocol LandKeeperTransport: Sendable {
    /// Send a server event to clients.
    ///
    /// - Parameters:
    ///   - event: The server event to send.
    ///   - target: The target recipients (session, player, broadcast, etc.).
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async
    
    /// Trigger immediate state synchronization to all connected players.
    ///
    /// No live keeper calls it (it syncs in its turns, #546 L2d); a re-evaluation keeper with a
    /// transport (`ReevaluationOutputMode.transportAndSink`) does from its sync loop, until #612.
    /// The default does nothing.
    func syncNowFromTransport() async
    
    /// Sync only broadcast changes (optimized for player leaving).
    ///
    /// No live keeper calls it (a leave's sync runs in its turn, #546 L2d); a re-evaluation
    /// keeper with a transport does after a replayed leave, until #612. The default does nothing.
    func syncBroadcastOnlyFromTransport() async
    
    /// Notify transport that the land has been destroyed.
    ///
    /// Called after all destroy handlers (OnFinalize, AfterFinalize) have completed.
    /// This allows the transport layer to perform cleanup, such as removing the land
    /// from LandManager's registry.
    func onLandDestroyed() async

    /// The land failed (#535): a failure it can't recover from ended it, and its teardown has
    /// started. Called once, from the teardown's task, before the destroy handlers run.
    ///
    /// Close the land's sessions with 4016 (`landFailed`) and return once they are closed;
    /// never wait for the destroy here: the keeper runs its destroy after this returns, so a
    /// wait for the destroy would never end. The default does nothing, and the keeper still
    /// tears the land down; a transport that holds sessions must close them itself.
    func landDidFail(_ failure: LandFailure) async

    /// The land failed (#535): from now on, enqueue no new state or event frame. Called by the
    /// keeper synchronously, in the segment that marks the failure, before any await, so a send
    /// already past its own checks (a legacy cycle resuming) stops too. Frames already handed to
    /// the writer still go out; action responses and errors are exempt. The default blocks
    /// nothing: a transport that sends on its own schedule must stop its state and event output
    /// when this is called.
    nonisolated func closeOutputs(for failure: LandFailure)

    /// Whether `keeper` may call `runSyncPhaseInTurn` from inside its own actor turn.
    ///
    /// `true` only when this transport is attached to that keeper (identity) and runs on its
    /// serial executor. A keeper asks this once per turn; a transport attached to another keeper
    /// answers `false`, so no keeper ever reaches an `assumeIsolated` that would trap.
    ///
    /// A live keeper also asks it at the attach (`init(transport:)`, `setTransport(_:)`): `false`
    /// there stops the process, because a live keeper syncs only in its turns (#546 L2d). No
    /// default: a transport answers for itself (#546 L2d-3).
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool

    /// Admits `sessionID` as joining `playerID`, in the keeper's join (#69).
    ///
    /// Called by the keeper inside its actor turn, in the same synchronous segment as the
    /// player's insert or, for a first join with an OnJoin handler, as the append of its OnJoin
    /// input, and only for a join that asked for it (`joinReportingAdmission`) when
    /// `runsSyncPhaseInTurn(of:)` is `true` for the caller. Being synchronous, the join cannot
    /// suspend between that state change and the admission. Returns whether the transport
    /// admitted the session; `false` leaves the admission to the join's caller after the join
    /// returns. An implementation that is an actor enters its own isolation with
    /// `assumeIsolated`.
    ///
    /// `joinSequence` is the sequence of the join's OnJoin input, `nil` when the join has none
    /// (its insert is the whole join). The keeper reports it again when a turn consumes it
    /// (`noteJoinInputsConsumed`).
    ///
    /// A transport that returns `.admittedCompletesInTurn` must also implement
    /// `noteJoinInputsConsumed` and `hasJoinsAwaitingSync`: with their defaults the join is never
    /// completed. The default (`.notAdmitted`) needs neither. Only the package's in-turn join
    /// (`joinReportingAdmission(admitThroughTransport: true)`) asks; the public `join` doesn't.
    func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission

    /// Whether the transport refuses this join for `playerID`, the player CanJoin resolved: a
    /// stale join attempt that would supersede a newer session of that player (#234).
    ///
    /// Called by the keeper under the same conditions as `admitJoiningSession`, in the segment
    /// of the CanJoin decision, before anything acts on the player (the player limit, the kick
    /// of its old session, the insert). `true` ends the join with nothing changed. An
    /// implementation that is an actor enters its own isolation with `assumeIsolated`.
    ///
    /// The join still suspends after the check (its hold point, the kick's leave). The answer
    /// stays valid until the join returns because its inputs don't change meanwhile: the
    /// transport changes them only in work it serializes with this join (the adapter's
    /// membership queue, which holds for the whole keeper join) or synchronously inside it.
    func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool

    /// The join inputs (OnJoin) a keeper turn just applied, in order, each with whether its
    /// handler threw. Called by the keeper inside the turn that applied them (input, tick or
    /// drain turn), after the inputs and before the turn's output step, only when
    /// `runsSyncPhaseInTurn(of:)` is `true` for the caller and the keeper is live. Synchronous.
    func noteJoinInputsConsumed(_ results: [JoinInputResult])

    /// Whether an admitted join is ready to complete and waits for a committed sync phase
    /// (in-turn joins, #69). A keeper without periodic sync runs a sync phase for it. Read inside
    /// the keeper's turn; synchronous.
    var hasJoinsAwaitingSync: Bool { get }

    /// Returns once the outbound writer no longer holds a state element from an earlier sync
    /// phase. A keeper without periodic sync waits on it before retrying a sync phase that was
    /// deferred by back-pressure (`.deferredBackPressure`), and retries as soon as it returns.
    /// No default (#546 L2d-3): one that returned at once would make a transport that defers
    /// retry its sync-only turn again and again until its writer drains. A transport that never
    /// defers may return at once. It returns on a cancel too: a turn core cancels the wait of a
    /// retry it abandoned (an attach, a detach, the land's end).
    func waitForWriterDrainForInTurnSync() async

    /// Whether the transport records in-turn sync folds (`noteInTurnSyncFold`): true only while
    /// it profiles. Read once when the transport is attached, so with profiling off a fold costs
    /// one cached check.
    var recordsInTurnSyncFolds: Bool { get }

    /// A tick turn started that carries a folded sync (#232): called once per such turn, at its
    /// start, with how late the turn started against the deadline the sync folded on.
    /// Synchronous and cheap (counters); called only if `recordsInTurnSyncFolds`.
    func noteInTurnSyncFold(_ fold: InTurnSyncFold)

    /// A tick turn ran its sync phase only for ready joins (#69): no sync was due by the cadence.
    /// Synchronous and cheap (a counter); called only if `recordsInTurnSyncFolds`.
    func noteInTurnJoinSyncTick()

    /// The synchronous output step of a keeper turn.
    ///
    /// Called by the keeper inside its actor turn, with no suspension point between the turn's
    /// state changes and this call: enqueue `events` in emit order (to the outbound writer, or to
    /// the opcode 107 queue), then, if `includeSync`, plan and commit a full sync phase on
    /// `state` and enqueue its frames after those events. Being synchronous, the turn cannot
    /// suspend in it. An implementation that is an actor runs on the keeper's executor and enters
    /// its own isolation with `assumeIsolated`.
    ///
    /// `recording`: what the keeper's sync stream records of this turn (its kind and where the
    /// phase reads the state), nil when the keeper doesn't record it. The phase writes nothing
    /// into the keeper: it returns its sync-stream entries as drafts, in order, and the keeper
    /// numbers and submits them in the same turn (#553).
    ///
    /// Only called when `runsSyncPhaseInTurn(of:)` returned `true` for the caller.
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput
}

// MARK: - In-turn sync

/// A server event emitted during a keeper turn, handed to the transport inside that turn.
public struct InTurnServerEvent: Sendable {
    public let event: AnyServerEvent
    public let target: EventTarget
    /// The keeper's output sequence of the event (for the recorded sync stream's events hash).
    public let sequence: Int64?

    public init(event: AnyServerEvent, target: EventTarget, sequence: Int64? = nil) {
        self.event = event
        self.target = target
        self.sequence = sequence
    }
}

/// What the keeper's sync stream records of a turn whose sync phase runs in it: the turn's kind
/// and where the phase reads the state, taken by the keeper in the turn (#553).
public struct InTurnSyncRecording: Sendable, Equatable {
    package let turnKind: ReevaluationRecordedSyncOutput.TurnKind
    package let position: SyncReadPosition

    package init(turnKind: ReevaluationRecordedSyncOutput.TurnKind, position: SyncReadPosition) {
        self.turnKind = turnKind
        self.position = position
    }
}

/// A sync-stream entry a sync phase made, not yet numbered: the keeper gives it its stream
/// index (and an output its index within the tick) and submits it (#553).
public struct SyncStreamDraft: Sendable {
    package enum Entry: Sendable {
        /// A committed plan's output; `make` gets its stream index and its index in the tick.
        case output(observedTickId: Int64?, make: @Sendable (_ streamIndex: UInt64, _ index: Int) -> ReevaluationRecordedSyncOutput)
        /// A seed or clear marker; `make` gets its stream index and where a read would read the
        /// state at numbering (a clear records its sequence and, tickless, its `afterPass`).
        case marker(make: @Sendable (_ streamIndex: UInt64, _ position: SyncReadPosition) -> ReevaluationRecordedSyncMarker)
    }

    package let entry: Entry

    package init(_ entry: Entry) {
        self.entry = entry
    }
}

/// What `LandKeeperTransport.runSyncPhaseInTurn` returns: what it did, and the sync-stream
/// entries it made, for the keeper to number and submit (#553).
public struct InTurnSyncOutput: Sendable {
    public let result: InTurnSyncResult
    package let syncStream: [SyncStreamDraft]
    /// Events are still queued after a committed phase (kept by it, or queued after it): on a
    /// land without periodic sync the keeper then requests one sync-only turn (#546 L2a).
    package let keepsEvents: Bool
    /// What a settle phase (`LandKeeperSettlePort.runSettlePhaseInTurn`) did; nil for any other
    /// phase.
    package let settle: InTurnSettleCommit?

    /// A phase that made no sync-stream entries.
    public init(_ result: InTurnSyncResult) {
        self.result = result
        self.syncStream = []
        self.keepsEvents = false
        self.settle = nil
    }

    package init(
        _ result: InTurnSyncResult,
        syncStream: [SyncStreamDraft],
        keepsEvents: Bool = false,
        settle: InTurnSettleCommit? = nil
    ) {
        self.result = result
        self.syncStream = syncStream
        self.keepsEvents = keepsEvents
        self.settle = settle
    }
}

/// The debug freeze settle a keeper's settle turn runs (#546 L2d-1): the freeze generation it
/// settles, passed only to that turn's phase call, so no other phase sees it.
package struct InTurnSettle: Sendable, Equatable {
    package let generation: UInt64

    package init(generation: UInt64) {
        self.generation = generation
    }
}

/// What the transport's settle phase did, in the keeper's settle turn.
package enum InTurnSettleCommit: Sendable, Equatable {
    /// The phase planned and committed the copy. `clearDirtyFlags`: as
    /// `InTurnSyncResult.committed`'s. `membershipEpoch`: read in the same segment, so a join or
    /// leave after it isn't in the copy.
    case committed(membershipEpoch: UInt64, clearDirtyFlags: Bool)
    /// No members: the copy is the settle's, nothing was planned and the dirty flags stay.
    case empty(membershipEpoch: UInt64)
    /// The transport refused the settle; nothing was planned.
    case refused(InTurnSettleRefusal)
    /// The plan threw; nothing of it was committed or sent. The keeper ends the land in the turn.
    case failed(LandFailure)
}

/// Why a settle turn ran no settle phase.
package enum InTurnSettleRefusal: Sendable, Equatable {
    /// The port isn't this keeper's in-turn settle port, or the freeze generation isn't the
    /// transport's current one.
    case notCurrent
    /// The transport's output is closed (its land failed, or it was torn down).
    case outputClosed
    /// The writer holds a sync cycle's element again: the settle waits for it and retries.
    case writerBusy
}

/// A transport that runs the debug freeze settle in its keeper's turn (#546 L2d-1). A package
/// refinement, so `LandKeeperTransport` gains no public requirement; only `TransportAdapter`
/// conforms.
package protocol LandKeeperSettlePort: LandKeeperTransport {
    /// The settle's sync phase, called by the keeper inside its settle turn, on the shared
    /// executor: no frozen defer, no back-pressure deferral and no joiners. `output.settle`
    /// says what it did.
    func runSettlePhaseInTurn<S: StateNodeProtocol>(
        state: S,
        settle: InTurnSettle,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput
}

/// Why a sync-only turn was requested (`LandKeeper.syncTurnNow(via:reason:ticket:)`): for
/// diagnostics and tests; no handling depends on it.
@PlainData
package enum SyncTurnReason: Hashable, Sendable {
    /// An explicit `syncNow()`.
    case syncNow
    /// Events still queued after a committed phase, on a land without periodic sync.
    case keptEvents
    /// The sync-lag timer found a pending mark or a resync due.
    case lagTimer
    /// The repair after a standalone firstSync found its commit behind.
    case behindCommitRepair
    /// The freeze's resume, for the syncs it deferred.
    case resume
    /// The keeper's broadcast-only bridge (`syncBroadcastOnlyFromTransport`) on an in-turn
    /// adapter: a full sync-only phase covers broadcast-only changes (#546 L2b).
    case broadcastOnly
    /// The debug freeze settle (`LandKeeper.settleTurn(via:fence:)`, #546 L2d-1).
    case settle
}

/// What `LandKeeperTransport.runSyncPhaseInTurn` did.
public enum InTurnSyncResult: Sendable, Equatable {
    /// The transport does not run sync phases in the keeper's turn.
    case unsupported
    /// The events were enqueued; no sync phase was requested.
    case notRequested
    /// A sync phase was requested but skipped (no members, or the land is frozen): nothing was
    /// planned and the request is consumed.
    case skipped
    /// A sync phase was requested but deferred because the land's outbound writer still holds a
    /// state element from an earlier phase (back-pressure). Nothing was planned: the dirty flags
    /// and the queued events (opcode 107) are kept, and the turn's request is consumed. A land
    /// with periodic sync re-syncs on its next sync-only turn; a land without one retries once
    /// after the writer drains.
    case deferredBackPressure
    /// The sync phase committed. `clearDirtyFlags`: the plan diffed every synced field, so the
    /// keeper clears the dirty flags now, in the same turn (clearing is part of the commit).
    case committed(clearDirtyFlags: Bool)
    /// The sync plan threw and committed nothing. The keeper ends the land on it, as on
    /// `landFailed` with kind `.syncPlan` (#535). A transport that can name the failure reports
    /// `landFailed` instead.
    case failed
    /// The sync phase failed in a way that can't be brought back to a fully correct state
    /// (#535): a plan that threw, or a value or frame that didn't convert or encode. Nothing of
    /// it was committed or sent. The keeper ends the land in the same turn (`LandKeeper.failure`);
    /// a position without a tick or pass gets the keeper's.
    case landFailed(LandFailure)
}

extension LandKeeperTransport {
    /// Default: nothing; only a re-evaluation keeper's sync loop calls it (until #612).
    public func syncNowFromTransport() async {}

    /// Default: nothing; only a re-evaluation keeper's replayed leave calls it (until #612).
    public func syncBroadcastOnlyFromTransport() async {}

    /// Default: nothing; the keeper still tears the land down.
    public func landDidFail(_ failure: LandFailure) async {}

    /// Default: nothing is blocked.
    public nonisolated func closeOutputs(for failure: LandFailure) {}

    /// Default: nothing is admitted; the join's caller admits after the join returns.
    public func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission { .notAdmitted }
    /// No join is refused.
    public func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool { false }

    /// Default: nothing.
    public func noteJoinInputsConsumed(_ results: [JoinInputResult]) {}

    /// Default: none.
    public var hasJoinsAwaitingSync: Bool { false }

    /// Default: folds are not recorded.
    public var recordsInTurnSyncFolds: Bool { false }

    /// Default: nothing.
    public func noteInTurnSyncFold(_ fold: InTurnSyncFold) {}

    /// Default: nothing.
    public func noteInTurnJoinSyncTick() {}
}

/// What `LandKeeperTransport.admitJoiningSession` did.
public enum JoinAdmission: Sendable, Equatable {
    /// Not admitted: the join's caller admits after the join returns.
    case notAdmitted
    /// Admitted; the join's caller completes the join after it returns (the join awaits its
    /// OnJoin turn as before).
    case admitted
    /// Admitted, and the transport completes the join in a turn (#69): the keeper doesn't await
    /// the OnJoin turn; the transport learns of it through `noteJoinInputsConsumed`.
    case admittedCompletesInTurn

    public var isAdmitted: Bool { self != .notAdmitted }
}

/// A join input (OnJoin) a keeper turn applied (`LandKeeperTransport.noteJoinInputsConsumed`).
/// OnJoin can't throw (#586), so an applied join always completed.
public struct JoinInputResult: Sendable, Equatable {
    /// The input's sequence, as passed to `admitJoiningSession(joinSequence:)`.
    public let sequence: Int64

    public init(sequence: Int64) {
        self.sequence = sequence
    }
}

/// What a destroyed keeper keeps instead of its transport (#346): no reference to the adapter,
/// so the land is released, and a count of the calls late keeper work still makes (logged
/// once), so they are not dropped silently.
final class ReleasedLandTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let landID: String
    private let logger: Logger

    init(landID: String, logger: Logger) {
        self.landID = landID
        self.logger = logger
    }

    var dropped: Int { lock.withLock { count } }

    private func drop(_ call: String) {
        let first: Bool = lock.withLock {
            count += 1
            return count == 1
        }
        if first {
            logger.warning("A destroyed land's keeper made a transport call; dropped and counted", metadata: [
                "landID": .string(landID),
                "call": .string(call),
            ])
        }
    }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async { drop("sendEvent") }
    func syncNowFromTransport() async { drop("syncNow") }
    func syncBroadcastOnlyFromTransport() async { drop("syncBroadcastOnly") }
    func onLandDestroyed() async { drop("onLandDestroyed") }
    func landDidFail(_ failure: LandFailure) async { drop("landDidFail") }
    /// No keeper runs a phase through it: it serves none (the attach check exempts it).
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { false }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        drop("runSyncPhaseInTurn")
        return InTurnSyncOutput(.unsupported)
    }
    func waitForWriterDrainForInTurnSync() async {}
}
