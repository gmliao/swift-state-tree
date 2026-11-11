// Sources/SwiftStateTreeTransport/StopLandResult.swift
//
// What stopping a land did (#102).

/// The result of `LandServerProtocol.stopLand(landID:)` (the admin API's
/// `DELETE /admin/lands/:landID`).
public enum StopLandResult: Sendable, Equatable {
    /// No live instance has this land ID.
    case notFound
    /// The land was stopped: its sessions left (OnLeave ran) and were closed with 4014
    /// (`SessionClose.Code.landStopped`), then it was destroyed (its destroy handlers and save).
    /// `timedOut` is true when the stop passed its bound (the host's `shutdownTimeout`) first:
    /// what was left of it, the destroy and the save, goes on in the background.
    case stopped(timedOut: Bool)
}
