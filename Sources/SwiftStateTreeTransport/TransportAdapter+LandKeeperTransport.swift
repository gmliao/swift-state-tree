// Sources/SwiftStateTreeTransport/TransportAdapter+LandKeeperTransport.swift

import Foundation
import SwiftStateTree

// MARK: - LandKeeperTransport Protocol Conformance

extension TransportAdapter: LandKeeperTransport, LandKeeperSettlePort {
    public func sendEventToTransport(_ event: AnyServerEvent, to target: SwiftStateTree.EventTarget) async {
        // TransportAdapter.sendEvent already accepts SwiftStateTree.EventTarget
        // and handles the conversion internally
        await self.sendEvent(event, to: target)
    }
    
    /// One requested sync-only turn. No keeper calls it on this adapter: a live keeper syncs in its
    /// turns, and `TransportAdapter.init` takes only a live keeper, so no re-evaluation keeper
    /// (`ReevaluationOutputMode.transportAndSink`) holds one. It stays as the witness until #612.
    public func syncNowFromTransport() async {
        await self.syncNow()
    }

    /// One requested broadcast-only sync turn. No keeper calls it on this adapter (see
    /// `syncNowFromTransport()`); it stays as the witness until #612.
    public func syncBroadcastOnlyFromTransport() async {
        await self._syncBroadcastOnlyImpl()
    }

    /// `true` only for this adapter's own keeper, whose executor it shares (`unownedExecutor`).
    public nonisolated func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool {
        isAttached(to: keeper)
    }

    /// Called by the keeper inside its join, on the shared executor. `assumeIsolated` traps off
    /// that executor.
    public nonisolated func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        assumeIsolated { adapter in
            adapter.admitJoiningSessionIsolated(playerID: playerID, clientID: clientID, sessionID: sessionID, joinSequence: joinSequence)
        }
    }

    /// Called by the keeper in its join, in the segment of the CanJoin decision.
    public nonisolated func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool {
        assumeIsolated { adapter in
            adapter.refusesResolvedJoinIsolated(playerID: playerID, sessionID: sessionID)
        }
    }

    /// Called by the keeper inside the turn that applied the join inputs.
    public nonisolated func noteJoinInputsConsumed(_ results: [JoinInputResult]) {
        assumeIsolated { adapter in
            adapter.noteJoinInputsConsumedIsolated(results)
        }
    }

    /// Read by the keeper inside its turn.
    public nonisolated var hasJoinsAwaitingSync: Bool {
        assumeIsolated { adapter in
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

    /// Returns on a cancel too: a core abandons the retry that waits here when the binding
    /// moves or the land ends, and cancels its worker (K2-2 commit 3c), and the writer's wait
    /// honours that. So does the test override's loop.
    public func waitForWriterDrainForInTurnSync() async {
        await outboundWriter.waitForSyncCycleDrain()
        while !Task.isCancelled, writerBackPressureForcedForTesting() {
            try? await safeTaskSleep(for: .milliseconds(1))
        }
    }

    /// Called by the keeper inside its turn. `assumeIsolated` checks that this runs on the shared
    /// executor (it traps otherwise) and enters the adapter's isolation without a hop.
    public nonisolated func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        assumeIsolated { adapter in
            adapter.runSyncPhaseInTurnIsolated(state: state, events: events, includeSync: includeSync, recording: recording)
        }
    }
    
    /// Called by the keeper inside its settle turn (#546 L2d-1), on the shared executor.
    /// `assumeIsolated` traps off that executor.
    package nonisolated func runSettlePhaseInTurn<S: StateNodeProtocol>(
        state: S,
        settle: InTurnSettle,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        assumeIsolated { adapter in
            adapter.runSettlePhaseInTurnIsolated(state: state, settle: settle, recording: recording)
        }
    }

    /// The land failed (#535): the output gate closes, in the failing segment.
    public nonisolated func closeOutputs(for failure: LandFailure) {
        outputGate.close(failure)
    }

    /// The land failed (#535): returns once its sessions are closed with 4016. The keeper's
    /// destroy follows, then `onLandDestroyed`.
    ///
    /// With a host (`landFailureHook`), the host stops the instance: it detaches it, its router
    /// runs each session's leave (no OnLeave, the land has failed) and closes it with 4016, and
    /// the hook returns once that is done. The stop's destroy joins this land's teardown. Built
    /// directly, without a hook, the adapter closes every session it holds.
    public func landDidFail(_ failure: LandFailure) async {
        if let landFailureHook, await landFailureHook() { return }
        await closeSessionsForLandFailure(failure)
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
