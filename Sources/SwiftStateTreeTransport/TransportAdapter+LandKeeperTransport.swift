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
    public nonisolated func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        guard inTurnSyncEnabled else { return .notAdmitted }
        return assumeIsolated { adapter in
            adapter.admitJoiningSessionIsolated(playerID: playerID, clientID: clientID, sessionID: sessionID, joinSequence: joinSequence)
        }
    }

    /// Called by the keeper inside the turn that applied the join inputs (in-turn sync only).
    public nonisolated func noteJoinInputsConsumed(_ results: [JoinInputResult]) {
        guard inTurnSyncEnabled else { return }
        assumeIsolated { adapter in
            adapter.noteJoinInputsConsumedIsolated(results)
        }
    }

    /// Read by the keeper inside its turn (in-turn sync only).
    public nonisolated var hasJoinsAwaitingSync: Bool {
        guard inTurnSyncEnabled else { return false }
        return assumeIsolated { adapter in
            adapter.hasJoinsAwaitingSyncIsolated()
        }
    }

    /// Returns once the writer holds no sync cycle element (and, in tests, once the forced
    /// back-pressure is off).
    /// True while this adapter profiles (`profilerCounters`); fixed for the adapter's life.
    public nonisolated var recordsInTurnSyncFolds: Bool { profilerCounters != nil }

    public nonisolated func noteInTurnSyncFold(_ fold: InTurnSyncFold) {
        profilerCounters?.recordSyncFold(fold)
    }

    public nonisolated func noteInTurnJoinSyncTick() {
        profilerCounters?.incrementSyncJoinTicks()
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
        stopSyncLagTimer()
        await outboundWriter.finish(timeout: Self.outboundTeardownTimeout)
        await onLandDestroyedCallback?()
        // A transport of this land only (not a shared one, whose delegate is the router) holds
        // this adapter as its delegate while the adapter holds it: a reference cycle. This
        // instance releases it, only if it is still the delegate (#346). Any `Transport`.
        await transport.releaseDelegate(ifIdenticalTo: self)
    }
}
