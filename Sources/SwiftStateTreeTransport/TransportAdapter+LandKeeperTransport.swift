// Sources/SwiftStateTreeTransport/TransportAdapter+LandKeeperTransport.swift

import Foundation
import SwiftStateTree

// MARK: - LandKeeperTransport Protocol Conformance

extension TransportAdapter: LandKeeperTransport {
    public func sendEventToTransport(_ event: AnyServerEvent, to target: SwiftStateTree.EventTarget) async {
        // TransportAdapter.sendEvent already accepts SwiftStateTree.EventTarget
        // and handles the conversion internally
        await self.sendEvent(event, to: target)
    }
    
    public func syncNowFromTransport() async {
        await self.syncNow()
    }
    
    public func syncBroadcastOnlyFromTransport() async {
        await self.syncBroadcastOnly()
    }

    /// `true` only with in-turn sync on and for this adapter's own keeper, whose executor it
    /// then shares (`unownedExecutor`).
    public nonisolated func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool {
        inTurnSyncEnabled && isAttached(to: keeper)
    }

    /// Called by the keeper inside its join, on the shared executor (in-turn sync only; the
    /// keeper never calls it otherwise). `assumeIsolated` traps off that executor.
    public nonisolated func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID) -> Bool {
        guard inTurnSyncEnabled else { return false }
        return assumeIsolated { adapter in
            adapter.admitJoiningSessionIsolated(playerID: playerID, clientID: clientID, sessionID: sessionID)
        }
    }

    /// Returns once the writer holds no sync cycle element (and, in tests, once the forced
    /// back-pressure is off).
    /// True while this adapter profiles (`profilerCounters`); fixed for the adapter's life.
    public nonisolated var recordsInTurnSyncFolds: Bool { profilerCounters != nil }

    public nonisolated func noteInTurnSyncFold(overdue: Bool) {
        profilerCounters?.incrementSyncFolds(overdue: overdue)
    }

    public func waitForWriterDrainForInTurnSync() async {
        await outboundWriter.waitForSyncCycleDrain()
        while writerBackPressureForcedForTesting() {
            try? await safeTaskSleep(for: .milliseconds(1))
        }
    }

    /// Called by the keeper inside its turn. `assumeIsolated` checks that this runs on the shared
    /// executor (it traps otherwise) and enters the adapter's isolation without a hop.
    public nonisolated func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        guard inTurnSyncEnabled else { return .unsupported }
        return assumeIsolated { adapter in
            adapter.runSyncPhaseInTurnIsolated(state: state, events: events, includeSync: includeSync)
        }
    }
    
    /// Called by the keeper after its destroy handlers ran (no more sync cycles). Stops the
    /// outbound writer, waits (bounded) for queued frames to reach the transport, then runs the
    /// land-destroyed callback. Frames issued after this are dropped and counted.
    public func onLandDestroyed() async {
        endSessionTicketsForTeardown()
        await outboundWriter.finish(timeout: Self.outboundTeardownTimeout)
        await onLandDestroyedCallback?()
    }
}
