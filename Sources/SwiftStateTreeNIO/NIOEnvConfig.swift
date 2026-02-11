// Sources/SwiftStateTreeNIO/NIOEnvConfig.swift
//
// NIO-related environment configuration (JWT, reevaluation records).
//
// Environment variables:
//
// | Key | Type | Default |
// |-----|------|---------|
// | JWT_SECRET_KEY | String | (required for JWT) |
// | JWT_ALGORITHM | String | HS256 |
// | JWT_ISSUER | String | (optional) |
// | JWT_AUDIENCE | String | (optional) |
// | REEVALUATION_RECORDS_DIR | String | ./reevaluation-records |

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// NIO environment configuration.
public struct NIOEnvConfig: Sendable {
    /// JWT configuration when JWT_SECRET_KEY is set; nil otherwise.
    public let jwtConfiguration: JWTConfiguration?

    /// Directory for reevaluation records (admin API).
    public let reevaluationRecordsDir: String

    /// Create config from environment.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NIOEnvConfig {
        let jwtConfiguration = JWTConfiguration.fromEnvironment()
        let reevaluationRecordsDir = EnvHelpers.getEnvString(
            key: EnvKeys.Reevaluation.recordsDir,
            defaultValue: "./reevaluation-records",
            environment: environment
        )
        return NIOEnvConfig(
            jwtConfiguration: jwtConfiguration,
            reevaluationRecordsDir: reevaluationRecordsDir
        )
    }
}
