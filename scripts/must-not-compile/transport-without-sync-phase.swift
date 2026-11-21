// expect-error: does not conform to protocol 'LandKeeperTransport'
// runSyncPhaseInTurn has no default (#546 L2d-3): one that answers true runs its own phase.
import SwiftStateTree

final class NoPhaseTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func waitForWriterDrainForInTurnSync() async {}
}
