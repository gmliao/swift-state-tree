// expect-error: does not conform to protocol 'LandKeeperTransport'
// waitForWriterDrainForInTurnSync has no default (#546 L2d-3): one that returned at once would
// make a transport that defers retry its sync-only turn in a loop.
import SwiftStateTree

final class NoDrainTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S, events: [InTurnServerEvent], includeSync: Bool, recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
}
