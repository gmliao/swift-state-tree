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

    /// Log output behavior. NO_COLOR: https://no-color.org/
    public enum Logging: Sendable {
        public static let useColors = "LOG_USE_COLORS"
        public static let noColor = "NO_COLOR"
    }
}
