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
        /// Deadline in milliseconds on one resolver group (Int, default 5000; 0 disables it).
        /// A timed-out resolver is cancelled and its result dropped (#104).
        public static let resolverTimeoutMs = "RESOLVER_TIMEOUT_MS"

        /// Deadline in milliseconds on the OnInitialize resolvers (Int, default 30000; 0 disables
        /// it). On a timeout the land's initialization fails and the land is torn down (#104).
        public static let resolverInitTimeoutMs = "RESOLVER_INIT_TIMEOUT_MS"

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
        /// Number of NIO event-loop threads for the WebSocket server
        /// (`NIOWebSocketServerConfiguration.eventLoopThreads`). Default: the CPUs the process
        /// may use (its CPU affinity and cgroup quota).
        public static let eventLoopThreads = "EVENT_LOOP_THREADS"
        /// WebSocket pong timeout in milliseconds (`NIOWebSocketServerConfiguration.pongTimeout`):
        /// a keepalive ping followed by no inbound frame within it closes the connection with 1001
        /// (going away). Must be below the 30 s ping interval. Default: 20000.
        public static let pongTimeoutMs = "WS_PONG_TIMEOUT_MS"
        /// Send backlog bound in bytes (`NIOWebSocketServerConfiguration.sendBacklogBound`): a
        /// session whose unwritable channel holds more is closed with 4008. 0 disables it.
        /// Default: 8388608 (8 MiB).
        public static let sendBacklogMaxBytes = "WS_SEND_BACKLOG_MAX_BYTES"
        /// Send backlog bound in milliseconds unwritable: a session whose channel stays
        /// unwritable longer is closed with 4008. 0 disables it. Default: 30000.
        public static let sendBacklogMaxUnwritableMs = "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS"
        /// Inbound backlog bound in messages (`NIOWebSocketServerConfiguration.inboundBacklogBound`):
        /// a session with more read but not yet delivered to the transport stops being read
        /// until half are delivered. 0 disables it. Default: 1024.
        public static let inboundBacklogMaxMessages = "WS_INBOUND_BACKLOG_MAX_MESSAGES"
        /// Inbound backlog bound in bytes, as `inboundBacklogMaxMessages`. 0 disables it.
        /// Default: 4194304 (4 MiB).
        public static let inboundBacklogMaxBytes = "WS_INBOUND_BACKLOG_MAX_BYTES"
    }

    /// Log output behavior. NO_COLOR: https://no-color.org/
    public enum Logging: Sendable {
        public static let useColors = "LOG_USE_COLORS"
        public static let noColor = "NO_COLOR"
    }
}
