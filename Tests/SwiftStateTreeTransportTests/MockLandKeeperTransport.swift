// Tests/SwiftStateTreeTransportTests/MockLandKeeperTransport.swift

import Foundation
import SwiftStateTree

/// Mock implementation of LandKeeperTransport for testing
actor MockLandKeeperTransport: LandKeeperTransport {
    var sendEventCallCount = 0
    var syncNowCallCount = 0
    var syncBroadcastOnlyCallCount = 0
    var lastEvent: AnyServerEvent?
    var lastTarget: EventTarget?
    
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        sendEventCallCount += 1
        lastEvent = event
        lastTarget = target
    }
    
    func syncNowFromTransport() async {
        syncNowCallCount += 1
    }
    
    func syncBroadcastOnlyFromTransport() async {
        syncBroadcastOnlyCallCount += 1
    }
    
    func onLandDestroyed() async {
        // Mock implementation - no-op for testing
    }
    
    func reset() {
        sendEventCallCount = 0
        syncNowCallCount = 0
        syncBroadcastOnlyCallCount = 0
        lastEvent = nil
        lastTarget = nil
    }
}

