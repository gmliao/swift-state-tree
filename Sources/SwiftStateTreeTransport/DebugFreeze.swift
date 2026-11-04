// Sources/SwiftStateTreeTransport/DebugFreeze.swift
//
// Types for the debug freeze / projection capability used by E2E state convergence checks.
// See `TransportAdapter.debugFreeze()`.

import Foundation
import SwiftStateTree

// MARK: - DTOs

/// Response of a debug freeze: the land is paused and one settle sync has been sent.
public struct DebugFreezeResponse: Codable, Sendable, Equatable {
    /// Identifies this freeze; a freeze while already frozen returns the same token.
    public let freezeToken: String
    /// Last committed tick when the settle cycle ran (-1 before the first tick).
    public let tickId: Int64
    /// Active freeze references after this call.
    public let freezeCount: Int
    /// True when the land was already frozen and no new settle cycle ran.
    public let reused: Bool

    public init(freezeToken: String, tickId: Int64, freezeCount: Int, reused: Bool) {
        self.freezeToken = freezeToken
        self.tickId = tickId
        self.freezeCount = freezeCount
        self.reused = reused
    }
}

/// Server projection captured from the settle cycle's state copy.
///
/// `state` uses the same value shape as the state wire (`SnapshotValue`), e.g. fixed-point
/// `Position2` as raw integers.
public struct DebugProjectionResponse: Codable, Sendable, Equatable {
    public let freezeToken: String
    public let tickId: Int64
    /// The player the projection is for; nil for the broadcast-only projection.
    public let playerID: String?
    /// True when a join or leave happened after the freeze; the projection no longer
    /// describes every client, so a comparison should be reported as inconclusive.
    public let membershipChanged: Bool
    /// Synced fields visible to `playerID` (broadcast plus that player's per-player view),
    /// or only broadcast fields when `playerID` is nil.
    public let state: [String: SnapshotValue]

    public init(
        freezeToken: String,
        tickId: Int64,
        playerID: String?,
        membershipChanged: Bool,
        state: [String: SnapshotValue]
    ) {
        self.freezeToken = freezeToken
        self.tickId = tickId
        self.playerID = playerID
        self.membershipChanged = membershipChanged
        self.state = state
    }
}

/// Body of a debug resume request.
public struct DebugResumeRequest: Codable, Sendable, Equatable {
    /// The token returned by the freeze being released.
    public let freezeToken: String

    public init(freezeToken: String) {
        self.freezeToken = freezeToken
    }
}

/// Response of a debug resume.
public struct DebugResumeResponse: Codable, Sendable, Equatable {
    /// References left on the current freeze after this call.
    public let freezeCount: Int
    /// True when this call released the last reference and the land runs again. False for a
    /// token of a freeze that was already released (e.g. by auto-resume).
    public let resumed: Bool

    public init(freezeCount: Int, resumed: Bool) {
        self.freezeCount = freezeCount
        self.resumed = resumed
    }
}

/// Errors of the debug freeze capability.
public enum DebugFreezeError: Error, Sendable, Equatable {
    /// A projection was requested while the land is not frozen.
    case notFrozen
    /// Drain and settle missed their deadline (in-flight work or another sync kept running);
    /// the freeze was released.
    case settleTimedOut
    /// The freeze was released (resume or auto-resume) before its settle finished.
    case released
}

// MARK: - Configuration

/// Defaults for the debug freeze capability.
public enum DebugFreezeDefaults: Sendable {
    public static let autoResumeTimeoutSeconds: Double = 30

    /// Auto-resume timeout from `EnvKeys.Debug.freezeTimeoutSeconds`, falling back to 30 s.
    /// The timer restarts on every freeze call.
    public static func autoResumeTimeout(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Duration {
        let seconds = EnvHelpers.getEnvDouble(
            key: EnvKeys.Debug.freezeTimeoutSeconds,
            defaultValue: autoResumeTimeoutSeconds,
            min: 0.01,
            environment: environment
        )
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}

// MARK: - Adapter bookkeeping

/// Per-adapter freeze state. Owned by `TransportAdapter`.
struct DebugFreezeState<State: StateNodeProtocol>: Sendable {
    struct Settled: Sendable {
        let state: State
        let tickId: Int64
        let membershipEpoch: UInt64
    }

    /// Active references to the current freeze.
    var count = 0
    /// Identifies the current (or last) freeze; bumped when a freeze starts from zero references.
    var generation: UInt64 = 0
    /// Token of the current freeze, returned to callers and required by resume.
    var token = ""
    /// Settle in progress or finished for the current freeze.
    var settleTask: Task<Settled, Error>?
    var settled: Settled?
    /// Syncs requested while frozen, run on resume.
    var deferredSyncNow = false
    var deferredBroadcastOnly = false
    /// Auto-resume timer; its own generation ignores timers replaced by a later freeze call.
    var autoResumeTask: Task<Void, Never>?
    var autoResumeGeneration: UInt64 = 0
    var autoResumeTimeout: Duration = DebugFreezeDefaults.autoResumeTimeout()
    /// Deadline for the drain plus the wait for `beginSync`.
    var settleDeadline: Duration = .seconds(10)
}
