// expect-error: does not conform to protocol 'LandKeeperTransport'
// runsSyncPhaseInTurn(of:) has no default (#546 L2d-3): a transport answers for itself.
import SwiftStateTree

final class NoAnswerTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func onLandDestroyed() async {}
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S, events: [InTurnServerEvent], includeSync: Bool, recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func waitForWriterDrainForInTurnSync() async {}
}
