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
    
    /// Called by the keeper after its destroy handlers ran (no more sync cycles). Stops the
    /// outbound writer, waits (bounded) for queued frames to reach the transport, then runs the
    /// land-destroyed callback. Frames issued after this are dropped and counted.
    public func onLandDestroyed() async {
        await outboundWriter.finish(timeout: Self.outboundTeardownTimeout)
        await onLandDestroyedCallback?()
    }
}
