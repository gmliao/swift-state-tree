import Foundation
import SwiftStateTree

extension TransportAdapter {
    /// One sync now: one sync-only turn on the keeper, run before this returns (#546 L2a).
    public func syncNow() async {
        await _syncNowImpl()
    }

    /// `syncNow()` with the outcome of its sync-only turn, which names who delivers its work:
    /// `.committed` this phase; `.deferredBackPressure` the writer-drain retry (or, on a land with
    /// periodic sync, its next phase); `.skipped` while frozen, the resume. Tests and the
    /// differential harness.
    package func syncNowReportingOutcome() async -> InTurnSyncResult {
        await requestSyncTurn(reason: .syncNow)
    }
}
