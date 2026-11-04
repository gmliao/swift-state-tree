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
    }

    /// Debug state routes (E2E convergence checks). These expose full land state and let a
    /// caller pause a land: never enable them in production.
    public enum Debug: Sendable {
        /// `true` registers `/admin/lands/:landID/debug/*` (also requires the admin API key).
        public static let enableDebugStateRoutes = "ENABLE_DEBUG_STATE_ROUTES"
        /// Seconds before a frozen land resumes on its own (default 30).
        public static let freezeTimeoutSeconds = "DEBUG_FREEZE_TIMEOUT_SECONDS"
    }

    /// Log output behavior. NO_COLOR: https://no-color.org/
    public enum Logging: Sendable {
        public static let useColors = "LOG_USE_COLORS"
        public static let noColor = "NO_COLOR"
    }
}
