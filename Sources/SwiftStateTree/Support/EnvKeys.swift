// Sources/SwiftStateTree/Support/EnvKeys.swift
//
// Centralized environment variable keys. Use constants instead of string literals
// to avoid typos and enable single-source refactoring.

import Foundation

/// Environment variable keys used across SwiftStateTree modules.
public enum EnvKeys: Sendable {

    /// Reevaluation record storage. Used by SwiftStateTreeReevaluationMonitor and SwiftStateTreeNIO.
    public enum Reevaluation: Sendable {
        public static let recordsDir = "REEVALUATION_RECORDS_DIR"
        /// `true` records each committed player's hash on sync outputs (`perPlayerHashes`), so a
        /// per-player mismatch names the player. Size: one hash per player with patches, per
        /// output. Default: off.
        public static let recordSyncDetails = "REEVALUATION_RECORD_SYNC_DETAILS"
        /// `true` records each scope's canonical patch list on sync outputs (`patches`), so a
        /// mismatch names the first differing path. Size: every patch value sent (roughly the size
        /// of every state update, per player for per-player scopes), with no cap: for short
        /// diagnostic runs only. Default: off.
        public static let recordSyncPatches = "REEVALUATION_RECORD_SYNC_PATCHES"
    }

    /// Debug state routes (E2E convergence checks). These expose full land state and let a
    /// caller pause a land: never enable them in production.
    public enum Debug: Sendable {
        /// `true` registers `/admin/lands/:landID/debug/*` (also requires the admin API key).
        public static let enableDebugStateRoutes = "ENABLE_DEBUG_STATE_ROUTES"
        /// Seconds before a frozen land resumes on its own (default 30).
        public static let freezeTimeoutSeconds = "DEBUG_FREEZE_TIMEOUT_SECONDS"
    }

    /// Land runtime behavior.
    public enum Runtime: Sendable {
        /// `false` turns off the per-land phase offset of the tick and sync loops
        /// (`LandLoopPhase`). Default: on.
        public static let landLoopPhaseOffset = "LAND_LOOP_PHASE_OFFSET"
        /// `false` turns off in-turn sync: the transport adapter keeps its own executor and the
        /// sync phase runs on the legacy `beginSync`/`endSync` path (`InTurnSync`). Default: on.
        public static let inTurnSync = "IN_TURN_SYNC"
        /// `true` records a full state snapshot with each live state hash (debug only).
        /// Default: off.
        public static let stateSnapshotRecording = "ENABLE_STATE_SNAPSHOT_RECORDING"
    }

    /// Network server settings.
    public enum Server: Sendable {
        /// Listen backlog (accept queue length) requested for the WebSocket server socket
        /// (`NIOWebSocketServerConfiguration.listenBacklog`). The kernel caps it at `somaxconn`.
        /// Default: 4096.
        public static let listenBacklog = "LISTEN_BACKLOG"
    }

    /// Log output behavior. NO_COLOR: https://no-color.org/
    public enum Logging: Sendable {
        public static let useColors = "LOG_USE_COLORS"
        public static let noColor = "NO_COLOR"
    }
}
