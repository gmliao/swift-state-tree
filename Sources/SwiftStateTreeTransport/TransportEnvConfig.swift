// Sources/SwiftStateTreeTransport/TransportEnvConfig.swift
//
// Centralized transport-related environment configuration.
// All env keys, types, defaults, and parsing rules are documented here.
//
// Environment variables:
//
// | Key | Type | Default | Rules |
// |-----|------|---------|-------|
// | ENABLE_DIRTY_TRACKING | Bool | init param | truthy: 1/true/yes/y/on; falsy: 0/false/no/n/off; unset uses init default |
// | USE_SNAPSHOT_FOR_SYNC | Bool | true | disabled when "false"/"0"/"no"/"off"; otherwise enabled |
// | ENABLE_CHANGE_OBJECT_METRICS | Bool | false | enabled only when "true"/"1"/"yes"/"y"/"on" |
// | CHANGE_OBJECT_METRICS_LOG_EVERY | Int | 10 | min 1 |
// | CHANGE_OBJECT_METRICS_EMA_ALPHA | Double | 0.2 | clamp 0.01–1.0 |
// | AUTO_DIRTY_TRACKING | Bool | true | enabled when "true"/"1"/"yes"/"y"/"on" |
// | AUTO_DIRTY_OFF_THRESHOLD | Double | 0.55 | clamp 0–1, resolved with hysteresis |
// | AUTO_DIRTY_ON_THRESHOLD | Double | 0.30 | clamp 0–1, resolved with hysteresis |
// | AUTO_DIRTY_REQUIRED_SAMPLES | Int | 30 | min 1 |
// | TRANSPORT_PROFILE_JSONL_PATH | String | (required) | Output path for profiling JSONL; unset = disabled |
// | TRANSPORT_PROFILE_INTERVAL_MS | Int | 1000 | Write interval in ms, min 100 |
// | TRANSPORT_PROFILE_SAMPLE_RATE | Double | 0.01 | Latency sample rate 0.001–1.0 |
// | TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL | Int | 500 | Max latency samples per interval, clamp 10–10000 |

import Foundation
import SwiftStateTree

/// Transport-related environment configuration.
///
/// Use `fromEnvironment(enableDirtyTrackingDefault:)` to read all transport env vars
/// with consistent parsing. Init parameters serve as defaults when env vars are unset.
public struct TransportEnvConfig: Sendable {
    public let enableDirtyTracking: Bool
    public let useSnapshotForSync: Bool
    public let enableChangeObjectMetrics: Bool
    public let changeObjectMetricsLogEvery: Int
    public let changeObjectMetricsEmaAlpha: Double
    public let enableAutoDirtyTracking: Bool
    public let autoDirtyOffThreshold: Double
    public let autoDirtyOnThreshold: Double
    public let autoDirtyRequiredConsecutiveSamples: Int
    public let profilingConfig: TransportProfilingConfig?

    /// Create config from environment. Init param `enableDirtyTrackingDefault` is used
    /// when ENABLE_DIRTY_TRACKING is unset.
    public static func fromEnvironment(
        enableDirtyTrackingDefault: Bool = true
    ) -> TransportEnvConfig {
        let env = ProcessInfo.processInfo.environment

        let enableDirtyTracking = EnvHelpers.getEnvBool(
            key: TransportEnvKeys.enableDirtyTracking,
            defaultValue: enableDirtyTrackingDefault,
            environment: env
        )

        let useSnapshotForSync = !EnvHelpers.isExplicitlyDisabled(key: TransportEnvKeys.useSnapshotForSync, environment: env)

        let enableChangeObjectMetrics = EnvHelpers.getEnvBool(
            key: TransportEnvKeys.enableChangeObjectMetrics,
            defaultValue: false,
            environment: env
        )

        let changeObjectMetricsLogEvery = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.changeObjectMetricsLogEvery, defaultValue: 10, environment: env))

        let changeObjectMetricsAlpha = EnvHelpers.getEnvDouble(
            key: TransportEnvKeys.changeObjectMetricsEmaAlpha,
            defaultValue: 0.2,
            min: 0.01,
            max: 1.0,
            environment: env
        )

        let enableAutoDirtyTracking = EnvHelpers.getEnvBool(
            key: TransportEnvKeys.autoDirtyTracking,
            defaultValue: true,
            environment: env
        )

        let parsedOffThreshold = EnvHelpers.getEnvDouble(
            key: TransportEnvKeys.autoDirtyOffThreshold,
            defaultValue: 0.55,
            min: 0,
            max: 1,
            environment: env
        )
        let parsedOnThreshold = EnvHelpers.getEnvDouble(
            key: TransportEnvKeys.autoDirtyOnThreshold,
            defaultValue: 0.30,
            min: 0,
            max: 1,
            environment: env
        )
        let resolvedOffThreshold = max(parsedOffThreshold, parsedOnThreshold + 0.01)
        let resolvedOnThreshold = min(parsedOnThreshold, resolvedOffThreshold - 0.01)

        let autoDirtyRequiredSamples = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.autoDirtyRequiredSamples, defaultValue: 30, environment: env))

        let profilingConfig = TransportProfilingConfig.fromEnvironment()

        return TransportEnvConfig(
            enableDirtyTracking: enableDirtyTracking,
            useSnapshotForSync: useSnapshotForSync,
            enableChangeObjectMetrics: enableChangeObjectMetrics,
            changeObjectMetricsLogEvery: changeObjectMetricsLogEvery,
            changeObjectMetricsEmaAlpha: changeObjectMetricsAlpha,
            enableAutoDirtyTracking: enableAutoDirtyTracking,
            autoDirtyOffThreshold: resolvedOffThreshold,
            autoDirtyOnThreshold: resolvedOnThreshold,
            autoDirtyRequiredConsecutiveSamples: autoDirtyRequiredSamples,
            profilingConfig: profilingConfig
        )
    }
}
