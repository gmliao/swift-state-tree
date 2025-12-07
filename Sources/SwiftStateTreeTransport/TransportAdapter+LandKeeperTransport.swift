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
}
