// Tests/SwiftStateTreeTransportTests/MockLandKeeperTransport.swift

import Foundation
import SwiftStateTree

/// A transport that records what each of its keeper's turns hands over (#546 L2d: a live
/// keeper's transport runs its sync phase in turn).
final class MockLandKeeperTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    private var phases = 0
    private var last: InTurnServerEvent?

    /// Events handed over, over all turns.
    var sendEventCallCount: Int { lock.withLock { events } }
    /// Sync phases run (a turn with `includeSync`).
    var syncPhaseCount: Int { lock.withLock { phases } }
    var lastEvent: AnyServerEvent? { lock.withLock { last?.event } }
    var lastTarget: EventTarget? { lock.withLock { last?.target } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}

    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events turnEvents: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        lock.withLock {
            events += turnEvents.count
            if let final = turnEvents.last { last = final }
            if includeSync { phases += 1 }
        }
        return InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }

    func reset() {
        lock.withLock {
            events = 0
            phases = 0
            last = nil
        }
    }
    func waitForWriterDrainForInTurnSync() async {}
}
