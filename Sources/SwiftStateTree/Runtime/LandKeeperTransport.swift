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

    /// Layer-3 spike: whether `runSyncPhaseInTurn` may be called from inside the actor turn of
    /// `keeper`: the transport is attached to that keeper (identity) and shares its serial
    /// executor. A transport attached to another keeper answers `false`, so that keeper never
    /// calls in (its `assumeIsolated` would trap).
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool

    /// Layer-3 spike: returns once the outbound writer no longer holds an earlier element (a
    /// tickless land re-triggers a sync-only turn that was deferred by back-pressure).
    func waitForWriterDrainForInTurnSync() async

    /// Layer-3 spike: the synchronous entry of a keeper turn's output and sync phase.
    ///
    /// Called by the keeper inside its actor turn, with no suspension point between the turn's
    /// state changes and this call: enqueue `events` in order (to the outbound writer, or to the
    /// opcode 107 queue), then, if `includeSync`, plan and commit a full sync phase on `state`
    /// and enqueue its frames. Synchronous, so the turn cannot suspend in it. An implementation
    /// that is an actor must run on the keeper's executor and enter its isolation with
    /// `assumeIsolated` (which traps on any other executor).
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult
}


// MARK: - In-turn sync (layer-3 spike)

/// A server event emitted during a keeper turn, handed to the transport inside that turn.
public struct InTurnServerEvent: Sendable {
    public let event: AnyServerEvent
    public let target: EventTarget

    public init(event: AnyServerEvent, target: EventTarget) {
        self.event = event
        self.target = target
    }
}

/// What `LandKeeperTransport.runSyncPhaseInTurn` did.
public enum InTurnSyncResult: Sendable, Equatable {
    /// The transport does not run sync phases in the keeper's turn.
    case unsupported
    /// Events were enqueued; no sync phase was requested.
    case notRequested
    /// A sync phase was requested but skipped (no members, or frozen): nothing was diffed.
    case skipped
    /// A sync phase was requested but deferred because the land's outbound writer still holds an
    /// earlier element (#86 back-pressure). Nothing was planned: the keeper keeps the dirty flags
    /// and the sync due, and opcode 107 events stay queued.
    case deferredBackPressure
    /// The sync phase committed. `clearDirtyFlags`: the plan diffed every synced field, so the
    /// keeper clears the dirty flags now, still in the same turn (clearing is part of commit).
    case committed(clearDirtyFlags: Bool)
    /// The sync plan threw and committed nothing; dirty flags stay set.
    case failed
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
