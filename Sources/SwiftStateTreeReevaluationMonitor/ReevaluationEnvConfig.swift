// Sources/SwiftStateTreeReevaluationMonitor/ReevaluationEnvConfig.swift
//
// Reevaluation-related environment configuration.
//
// Environment variables:
//
// | Key | Type | Default |
// |-----|------|---------|
// | REEVALUATION_RECORDS_DIR | String | ./reevaluation-records |

import Foundation
import SwiftStateTree

/// Reevaluation environment configuration.
public struct ReevaluationEnvConfig: Sendable {
    /// Directory for saving reevaluation records.
    public let recordsDir: String

    /// Create config from environment.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ReevaluationEnvConfig {
        let recordsDir = EnvHelpers.getEnvString(
            key: EnvKeys.Reevaluation.recordsDir,
            defaultValue: "./reevaluation-records",
            environment: environment
        )
        return ReevaluationEnvConfig(recordsDir: recordsDir)
    }
}
