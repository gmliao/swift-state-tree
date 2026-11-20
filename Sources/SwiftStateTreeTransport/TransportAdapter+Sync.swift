import Foundation
import SwiftStateTree

extension TransportAdapter {
    /// One sync now. In-turn: one sync-only turn on the keeper, run before this returns (#546 L2a).
    /// Off: the adapter's own cycle, until L2c removes it.
    public func syncNow() async {
        await _syncNowImpl()
    }

    /// `syncNow()` with the outcome of its sync-only turn, which names who delivers its work:
    /// `.committed` this phase; `.deferredBackPressure` the writer-drain retry (or, on a land with
    /// periodic sync, its next phase); `.skipped` while frozen, the resume. Off, the adapter's
    /// own cycle runs and the outcome is `.unsupported`. Tests and the differential harness.
    package func syncNowReportingOutcome() async -> InTurnSyncResult {
        guard inTurnSyncEnabled else {
            await _syncNowImpl()
            return .unsupported
        }
        return await requestSyncTurn(reason: .syncNow)
    }
}
