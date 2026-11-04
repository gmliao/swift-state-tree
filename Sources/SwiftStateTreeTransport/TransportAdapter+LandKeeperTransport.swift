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

    /// Layer-3 spike: the adapter shares its keeper's executor (`unownedExecutor`).
    public nonisolated var runsSyncPhaseOnKeeperExecutor: Bool { true }

    /// Layer-3 spike: called by the keeper inside its turn. `assumeIsolated` checks that this
    /// runs on the shared executor (it traps otherwise) and enters the adapter's isolation
    /// without a hop.
    public nonisolated func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        assumeIsolated { adapter in
            adapter.runSyncPhaseInTurnIsolated(state: state, events: events, includeSync: includeSync)
        }
    }
    
    /// Called by the keeper after its destroy handlers ran (no more sync cycles). Stops the
    /// outbound writer, waits (bounded) for queued frames to reach the transport, then runs the
    /// land-destroyed callback. Frames issued after this are dropped and counted.
    public func onLandDestroyed() async {
        await outboundWriter.finish(timeout: Self.outboundTeardownTimeout)
        await onLandDestroyedCallback?()
    }
}
