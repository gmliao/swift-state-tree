// Sources/SwiftStateTreeTransport/StopLandResult.swift
//
// What stopping a land did (#102).

/// The result of `LandServerProtocol.stopLand(landID:)` (the admin API's
/// `DELETE /admin/lands/:landID`).
public enum StopLandResult: Sendable, Equatable {
    /// No live instance has this land ID.
    case notFound
    /// The land was stopped: its sessions left and were closed with 4014
    /// (`SessionClose.Code.landStopped`), then it was destroyed (its destroy handlers and save).
    /// OnLeave ran on a tickless land; a tick land's queued leaves are currently dropped (#512).
    /// `timedOut` is true when the caller stopped waiting first: the stop passed its bound (the
    /// host's `shutdownTimeout`), or the calling task was cancelled. What was left of it, the
    /// destroy and the save, goes on in the background. A cancelled caller gets this even for
    /// an ID with no live instance.
    case stopped(timedOut: Bool)
}
