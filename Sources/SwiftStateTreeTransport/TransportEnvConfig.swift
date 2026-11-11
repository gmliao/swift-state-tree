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
// | USE_SYNC_TABLES | Bool | false | experimental: the broadcast diff on the typed sync tables (delta strategy only); enabled only when "true"/"1"/"yes"/"y"/"on" |
// | TYPED_LEAF_VALUES | Bool | false | experimental: a changed leaf of a known type is converted by its typed form on the typed sync tables (only where they are in effect); enabled only when "true"/"1"/"yes"/"y"/"on" |
// | SYNC_STRATEGY | String | init param | "delta" or "full-snapshot" (case-insensitive); unknown values use init default |
// | ENABLE_CHANGE_OBJECT_METRICS | Bool | false | enabled only when "true"/"1"/"yes"/"y"/"on" |
// | CHANGE_OBJECT_METRICS_LOG_EVERY | Int | 10 | min 1 |
// | CHANGE_OBJECT_METRICS_EMA_ALPHA | Double | 0.2 | clamp 0.01–1.0 |
// | AUTO_DIRTY_TRACKING | Bool | true | enabled when "true"/"1"/"yes"/"y"/"on" |
// | AUTO_DIRTY_OFF_THRESHOLD | Double | 0.55 | clamp 0–1, resolved with hysteresis |
// | AUTO_DIRTY_ON_THRESHOLD | Double | 0.30 | clamp 0–1, resolved with hysteresis |
// | AUTO_DIRTY_REQUIRED_SAMPLES | Int | 30 | min 1; counted in syncs, see AUTO_DIRTY_SAMPLE_EVERY |
// | AUTO_DIRTY_SAMPLE_EVERY | Int | 1 | clamp 1–1024; change metrics are collected on one sync in N |
// | TRANSPORT_PROFILE_JSONL_PATH | String | (required) | Output path for profiling JSONL; unset = disabled |
// | TRANSPORT_PROFILE_INTERVAL_MS | Int | 1000 | Write interval in ms, min 100 |
// | TRANSPORT_PROFILE_SAMPLE_RATE | Double | 0.01 | Latency sample rate 0.001–1.0 |
// | TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL | Int | 500 | Max latency samples per interval, clamp 10–10000 |
// | OUTBOUND_WRITER_MAX_BYTES | Int | 67108864 (64 MiB) | Per-land ceiling for frames queued in the outbound writer, min 1024 |

import Foundation
import SwiftStateTree

/// Transport-related environment configuration.
///
/// Use `fromEnvironment(enableDirtyTrackingDefault:)` to read all transport env vars
/// with consistent parsing. Init parameters serve as defaults when env vars are unset.
/// A config built with `init` reads no environment variable, except `USE_SYNC_TABLES`
/// (`useSyncTables`) and `TYPED_LEAF_VALUES` (`typedLeafValues`).
public struct TransportEnvConfig: Sendable {
    public let enableDirtyTracking: Bool
    public let useSnapshotForSync: Bool
    public let syncStrategy: SyncStrategy
    public let enableChangeObjectMetrics: Bool
    public let changeObjectMetricsLogEvery: Int
    public let changeObjectMetricsEmaAlpha: Double
    public let enableAutoDirtyTracking: Bool
    public let autoDirtyOffThreshold: Double
    public let autoDirtyOnThreshold: Double
    public let autoDirtyRequiredConsecutiveSamples: Int
    /// Change-object metrics (and so the auto dirty-tracking decision) are collected on one sync
    /// in this many (#391), clamped to 1...1024. The EMA weight and the required samples are
    /// scaled so a switch takes about as many syncs as when every sync is measured. 1 (the
    /// default) measures every sync. Above 1, the sampled syncs are at a fixed phase, so a
    /// workload whose busy syncs repeat with a period dividing N is always seen at the same point.
    public let autoDirtySampleEvery: Int
    public let profilingConfig: TransportProfilingConfig?
    /// Ceiling for the bytes queued in one adapter's `OutboundWriter`; frames over it are
    /// dropped and logged.
    public let outboundWriterMaxBytes: Int
    /// The broadcast diff runs on the typed sync tables instead of snapshots (`USE_SYNC_TABLES`,
    /// off by default, delta strategy only). The frames are the same bytes either way.
    ///
    /// Every config takes the environment's value, one built with `init` included, so a whole
    /// test run can be switched from outside; set the property to pin one side.
    package var useSyncTables = TransportEnvConfig.useSyncTablesFromEnvironment

    /// `useSyncTables`, for diagnostics and equivalence tests outside this package (a test that
    /// runs one script on both sides in one process). `USE_SYNC_TABLES` is the supported switch.
    /// An adapter reads its config once, when it is built: set this on the config before passing
    /// it to the adapter.
    @_spi(Diagnostics) public var syncTablesEnabled: Bool {
        get { useSyncTables }
        set { useSyncTables = newValue }
    }

    /// On the typed sync tables, a changed leaf field registered with the standard conversion
    /// is converted by its typed form (`SyncLeafWritable`) instead of `SnapshotValue.make(from:)`
    /// (`TYPED_LEAF_VALUES`, off by default). The frames are the same bytes either way. It takes
    /// effect wherever the tables are in effect: `USE_SYNC_TABLES`, or row addressing, which
    /// turns them on; elsewhere it is ignored.
    ///
    /// Every config takes the environment's value, as `useSyncTables` does.
    package var typedLeafValues = TransportEnvConfig.typedLeafValuesFromEnvironment

    /// `typedLeafValues`, for diagnostics and equivalence tests outside this package.
    /// `TYPED_LEAF_VALUES` is the supported switch. Set it before passing the config to an adapter.
    @_spi(Diagnostics) public var typedLeafValuesEnabled: Bool {
        get { typedLeafValues }
        set { typedLeafValues = newValue }
    }

    /// `TYPED_LEAF_VALUES`, read once per process.
    private static let typedLeafValuesFromEnvironment = EnvHelpers.getEnvBool(
        key: TransportEnvKeys.typedLeafValues,
        defaultValue: false,
        environment: ProcessInfo.processInfo.environment
    )

    /// `USE_SYNC_TABLES`, read once per process.
    private static let useSyncTablesFromEnvironment = EnvHelpers.getEnvBool(
        key: TransportEnvKeys.useSyncTables,
        defaultValue: false,
        environment: ProcessInfo.processInfo.environment
    )

    /// Default for `autoDirtySampleEvery`: every sync is measured.
    static let defaultAutoDirtySampleEvery = 1

    /// The range `autoDirtySampleEvery` is clamped to.
    static let autoDirtySampleEveryRange = 1...1024

    /// `value` clamped to `autoDirtySampleEveryRange`. The effective value is in the adapter's
    /// startup configuration log (`autoDirtySampleEvery`).
    static func clampedAutoDirtySampleEvery(_ value: Int) -> Int {
        min(max(value, autoDirtySampleEveryRange.lowerBound), autoDirtySampleEveryRange.upperBound)
    }

    /// Default for `outboundWriterMaxBytes` (64 MiB).
    public static let defaultOutboundWriterMaxBytes = 64 * 1024 * 1024

    public init(
        enableDirtyTracking: Bool,
        useSnapshotForSync: Bool,
        syncStrategy: SyncStrategy,
        enableChangeObjectMetrics: Bool,
        changeObjectMetricsLogEvery: Int,
        changeObjectMetricsEmaAlpha: Double,
        enableAutoDirtyTracking: Bool,
        autoDirtyOffThreshold: Double,
        autoDirtyOnThreshold: Double,
        autoDirtyRequiredConsecutiveSamples: Int,
        profilingConfig: TransportProfilingConfig?,
        outboundWriterMaxBytes: Int = TransportEnvConfig.defaultOutboundWriterMaxBytes,
        autoDirtySampleEvery: Int = 1
    ) {
        self.enableDirtyTracking = enableDirtyTracking
        self.useSnapshotForSync = useSnapshotForSync
        self.syncStrategy = syncStrategy
        self.enableChangeObjectMetrics = enableChangeObjectMetrics
        self.changeObjectMetricsLogEvery = changeObjectMetricsLogEvery
        self.changeObjectMetricsEmaAlpha = changeObjectMetricsEmaAlpha
        self.enableAutoDirtyTracking = enableAutoDirtyTracking
        self.autoDirtyOffThreshold = autoDirtyOffThreshold
        self.autoDirtyOnThreshold = autoDirtyOnThreshold
        self.autoDirtyRequiredConsecutiveSamples = autoDirtyRequiredConsecutiveSamples
        self.profilingConfig = profilingConfig
        self.outboundWriterMaxBytes = outboundWriterMaxBytes
        self.autoDirtySampleEvery = TransportEnvConfig.clampedAutoDirtySampleEvery(autoDirtySampleEvery)
    }

    /// Create config from environment. Init params `enableDirtyTrackingDefault` and
    /// `syncStrategyDefault` are used when the matching env var is unset.
    public static func fromEnvironment(
        enableDirtyTrackingDefault: Bool = true,
        syncStrategyDefault: SyncStrategy = .delta
    ) -> TransportEnvConfig {
        let env = ProcessInfo.processInfo.environment

        let enableDirtyTracking = EnvHelpers.getEnvBool(
            key: TransportEnvKeys.enableDirtyTracking,
            defaultValue: enableDirtyTrackingDefault,
            environment: env
        )

        let useSnapshotForSync = !EnvHelpers.isExplicitlyDisabled(key: TransportEnvKeys.useSnapshotForSync, environment: env)

        let syncStrategy = SyncStrategy.parse(env[TransportEnvKeys.syncStrategy], default: syncStrategyDefault)

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

        let autoDirtySampleEvery = clampedAutoDirtySampleEvery(EnvHelpers.getEnvInt(
            key: TransportEnvKeys.autoDirtySampleEvery,
            defaultValue: TransportEnvConfig.defaultAutoDirtySampleEvery,
            environment: env
        ))

        let profilingConfig = TransportProfilingConfig.fromEnvironment()

        let outboundWriterMaxBytes = max(1024, EnvHelpers.getEnvInt(
            key: TransportEnvKeys.outboundWriterMaxBytes,
            defaultValue: TransportEnvConfig.defaultOutboundWriterMaxBytes,
            environment: env
        ))

        return TransportEnvConfig(
            enableDirtyTracking: enableDirtyTracking,
            useSnapshotForSync: useSnapshotForSync,
            syncStrategy: syncStrategy,
            enableChangeObjectMetrics: enableChangeObjectMetrics,
            changeObjectMetricsLogEvery: changeObjectMetricsLogEvery,
            changeObjectMetricsEmaAlpha: changeObjectMetricsAlpha,
            enableAutoDirtyTracking: enableAutoDirtyTracking,
            autoDirtyOffThreshold: resolvedOffThreshold,
            autoDirtyOnThreshold: resolvedOnThreshold,
            autoDirtyRequiredConsecutiveSamples: autoDirtyRequiredSamples,
            profilingConfig: profilingConfig,
            outboundWriterMaxBytes: outboundWriterMaxBytes,
            autoDirtySampleEvery: autoDirtySampleEvery
        )
    }
}
