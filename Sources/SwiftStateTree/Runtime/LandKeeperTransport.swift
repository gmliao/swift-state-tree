import Foundation
import Logging

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
/// The keeper awaits `sendEventToTransport` and `syncBroadcastOnlyFromTransport` in ordered
/// delivery: with in-turn sync off, a tickless land's passes deliver one after another, in apply
/// order. An implementation must not await a keeper input (a join, a leave, an action or a
/// client event) from those two calls: that input's pass delivers behind the call's own
/// delivery, which waits for it, so both hang. Start the input in a task of its own instead,
/// without awaiting it there. `syncNowFromTransport` isn't ordered this way.
///
/// Example usage:
/// ```swift
/// extension TransportAdapter: LandKeeperTransport {
///     public func sendEvent(_ event: AnyServerEvent, to target: EventTarget) async {
///         await self.sendEvent(event, to: target)
///     }
///     
///     public func syncNow() async {
///         await self.syncNow()
///     }
///     
///     public func syncBroadcastOnly() async {
///         await self.syncBroadcastOnly()
///     }
/// }
/// ```
public protocol LandKeeperTransport: Sendable {
    /// Send a server event to clients.
    ///
    /// - Parameters:
    ///   - event: The server event to send.
    ///   - target: The target recipients (session, player, broadcast, etc.).
    ///
    /// Must not await a keeper input (see the protocol's doc): a legacy tickless pass awaits
    /// this call in ordered delivery.
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async
    
    /// Trigger immediate state synchronization to all connected players.
    ///
    /// This should extract the current state, compute diffs, and send updates
    /// to all connected players.
    func syncNowFromTransport() async
    
    /// Sync only broadcast changes (optimized for player leaving).
    ///
    /// This is an optimization for cases where only broadcast fields have changed
    /// (e.g., a player leaving). It should only extract and compare broadcast fields,
    /// avoiding per-player snapshot extraction.
    ///
    /// If not implemented, should fall back to `syncNowFromTransport()`.
    ///
    /// Must not await a keeper input (see the protocol's doc): a legacy tickless pass awaits
    /// this call in ordered delivery.
    func syncBroadcastOnlyFromTransport() async
    
    /// Notify transport that the land has been destroyed.
    ///
    /// Called after all destroy handlers (OnFinalize, AfterFinalize) have completed.
    /// This allows the transport layer to perform cleanup, such as removing the land
    /// from LandManager's registry.
    func onLandDestroyed() async

    /// Whether `keeper` may call `runSyncPhaseInTurn` from inside its own actor turn.
    ///
    /// `true` only when in-turn sync is on for this transport and it is attached to that keeper
    /// (identity) and runs on its serial executor (`InTurnSync`). A keeper asks this once per
    /// turn; a transport attached to another keeper, or with in-turn sync off, answers `false`, so
    /// no keeper ever reaches an `assumeIsolated` that would trap.
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
    /// deferred by back-pressure.
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
    /// Only called when `runsSyncPhaseInTurn(of:)` returned `true` for the caller.
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult
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
    /// The sync phase committed, as `committed`, and left a repair: a part of it was held back
    /// (a row that did not encode, with row addressing) and the next plan diffs it again. A land
    /// without periodic sync schedules one repair sync-only turn, as after a failed plan within
    /// its limit; a land with periodic sync relies on its next one.
    case committedWithRepairPending(clearDirtyFlags: Bool)
    /// The sync plan threw and committed nothing; the dirty flags stay set. `repairAllowed`: the
    /// failure count is still within the follow-up limit, so a land without periodic sync may
    /// schedule one repair sync-only turn (a land with periodic sync relies on its next one).
    case failed(repairAllowed: Bool)
}

extension LandKeeperTransport {
    /// Default: in-turn sync is not supported for any keeper.
    public func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { false }

    /// Default: nothing is admitted; the join's caller admits after the join returns.
    public func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission { .notAdmitted }
    /// No join is refused.
    public func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool { false }

    /// Default: nothing.
    public func noteJoinInputsConsumed(_ results: [JoinInputResult]) {}

    /// Default: none.
    public var hasJoinsAwaitingSync: Bool { false }

    /// Default: returns immediately.
    public func waitForWriterDrainForInTurnSync() async {}

    /// Default: folds are not recorded.
    public var recordsInTurnSyncFolds: Bool { false }

    /// Default: nothing.
    public func noteInTurnSyncFold(_ fold: InTurnSyncFold) {}

    /// Default: nothing.
    public func noteInTurnJoinSyncTick() {}

    /// Default: in-turn sync is not supported.
    public func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        .unsupported
    }
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
public struct JoinInputResult: Sendable, Equatable {
    /// The input's sequence, as passed to `admitJoiningSession(joinSequence:)`.
    public let sequence: Int64
    /// OnJoin threw: the keeper removed the input and the player it inserted.
    public let failed: Bool

    public init(sequence: Int64, failed: Bool) {
        self.sequence = sequence
        self.failed = failed
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
}
