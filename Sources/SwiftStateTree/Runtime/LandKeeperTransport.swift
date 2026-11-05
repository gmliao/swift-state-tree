import Foundation

/// Protocol defining transport operations that LandKeeper needs.
///
/// This protocol allows LandKeeper to communicate with the transport layer
/// without directly depending on transport implementations. This maintains
/// the architectural separation where Core (LandKeeper) doesn't depend on
/// Transport layer, while Transport layer depends on Core.
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

    /// Returns once the outbound writer no longer holds a state element from an earlier sync
    /// phase. A keeper without periodic sync waits on it before retrying a sync phase that was
    /// deferred by back-pressure.
    func waitForWriterDrainForInTurnSync() async

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
    /// The sync plan threw and committed nothing; the dirty flags stay set. `repairAllowed`: the
    /// failure count is still within the follow-up limit, so a land without periodic sync may
    /// schedule one repair sync-only turn (a land with periodic sync relies on its next one).
    case failed(repairAllowed: Bool)
}

extension LandKeeperTransport {
    /// Default: in-turn sync is not supported for any keeper.
    public func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { false }

    /// Default: returns immediately.
    public func waitForWriterDrainForInTurnSync() async {}

    /// Default: in-turn sync is not supported.
    public func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        .unsupported
    }
}

