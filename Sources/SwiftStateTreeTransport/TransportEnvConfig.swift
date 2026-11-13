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
// | USE_SYNC_TABLES | Bool | true | the broadcast diff on the typed sync tables (delta strategy only); "false"/"0"/"no"/"n"/"off" opts out to the snapshot diff, a fallback to be removed. Row addressing turns the tables on regardless |
// | PER_PLAYER_SYNC_TABLES | Bool | true | per-player fields diffed on typed per-player tables wherever the broadcast tables are in effect (#514); "false"/"0"/"no"/"n"/"off" opts out to today's per-player snapshot diff |
// | TYPED_LEAF_VALUES | Bool | true | a changed leaf of a known type is converted by its typed form on the typed sync tables (only where they are in effect); "false"/"0"/"no"/"n"/"off" opts out |
// | SYNC_STRATEGY | String | init param | "delta" or "full-snapshot" (case-insensitive); unknown values use init default |
// | TRANSPORT_PROFILE_JSONL_PATH | String | (required) | Output path for profiling JSONL; unset = disabled |
// | TRANSPORT_PROFILE_INTERVAL_MS | Int | 1000 | Write interval in ms, min 100 |
// | TRANSPORT_PROFILE_SAMPLE_RATE | Double | 0.01 | Latency sample rate 0.001–1.0 |
// | TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL | Int | 500 | Max latency samples per interval, clamp 10–10000 |
// | OUTBOUND_WRITER_MAX_BYTES | Int | 67108864 (64 MiB) | Per-land ceiling for frames queued in the outbound writer, min 1024 |
//
// Removed (the auto dirty switch and its change-object metric): ENABLE_CHANGE_OBJECT_METRICS,
// CHANGE_OBJECT_METRICS_LOG_EVERY, CHANGE_OBJECT_METRICS_EMA_ALPHA, AUTO_DIRTY_TRACKING,
// AUTO_DIRTY_OFF_THRESHOLD, AUTO_DIRTY_ON_THRESHOLD, AUTO_DIRTY_REQUIRED_SAMPLES and
// AUTO_DIRTY_SAMPLE_EVERY. They are ignored; the first adapter in a process logs a warning
// naming any that is set (`TransportRemovedEnvKeys`).

import Foundation
import SwiftStateTree

/// Transport-related environment configuration.
///
/// Use `fromEnvironment(enableDirtyTrackingDefault:)` to read all transport env vars
/// with consistent parsing. Init parameters serve as defaults when env vars are unset.
/// A config built with `init` reads no environment variable, except `USE_SYNC_TABLES`
/// (`useSyncTables`), `PER_PLAYER_SYNC_TABLES` (`perPlayerSyncTables`) and `TYPED_LEAF_VALUES`
/// (`typedLeafValues`).
public struct TransportEnvConfig: Sendable {
    public let enableDirtyTracking: Bool
    public let useSnapshotForSync: Bool
    public let syncStrategy: SyncStrategy
    public let profilingConfig: TransportProfilingConfig?
    /// Ceiling for the bytes queued in one adapter's `OutboundWriter`; frames over it are
    /// dropped and logged.
    public let outboundWriterMaxBytes: Int
    /// The broadcast diff runs on the typed sync tables instead of snapshots (`USE_SYNC_TABLES`,
    /// on by default, delta strategy only). The frames are the same bytes either way. Off is the
    /// snapshot diff, kept as a fallback to be removed later. Row addressing turns the tables on
    /// whatever this says, so with it in effect off is not an opt-out.
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

    /// Per-player fields are diffed on typed per-player tables (`SyncTablePerPlayerDiff`, #514)
    /// instead of per-player snapshots (`PER_PLAYER_SYNC_TABLES`, on by default). It takes effect
    /// wherever the broadcast tables are in effect; elsewhere it is ignored. Off is today's
    /// per-player snapshot diff, kept as the rollback.
    ///
    /// Every config takes the environment's value, as `useSyncTables` does.
    package var perPlayerSyncTables = TransportEnvConfig.perPlayerSyncTablesFromEnvironment

    /// `perPlayerSyncTables`, for diagnostics and equivalence tests outside this package.
    /// `PER_PLAYER_SYNC_TABLES` is the supported switch. Set it before passing the config to an
    /// adapter.
    @_spi(Diagnostics) public var perPlayerSyncTablesEnabled: Bool {
        get { perPlayerSyncTables }
        set { perPlayerSyncTables = newValue }
    }

    /// `PER_PLAYER_SYNC_TABLES`, read once per process.
    private static let perPlayerSyncTablesFromEnvironment = EnvHelpers.getEnvBool(
        key: TransportEnvKeys.perPlayerSyncTables,
        defaultValue: true,
        environment: ProcessInfo.processInfo.environment
    )

    /// On the typed sync tables, a changed leaf field registered with the standard conversion
    /// is converted by its typed form (`SyncLeafWritable`) instead of `SnapshotValue.make(from:)`
    /// (`TYPED_LEAF_VALUES`, on by default). The frames are the same bytes either way. It takes
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
        defaultValue: true,
        environment: ProcessInfo.processInfo.environment
    )

    /// `USE_SYNC_TABLES`, read once per process.
    private static let useSyncTablesFromEnvironment = EnvHelpers.getEnvBool(
        key: TransportEnvKeys.useSyncTables,
        defaultValue: true,
        environment: ProcessInfo.processInfo.environment
    )

    /// Default for `outboundWriterMaxBytes` (64 MiB).
    public static let defaultOutboundWriterMaxBytes = 64 * 1024 * 1024

    public init(
        enableDirtyTracking: Bool,
        useSnapshotForSync: Bool,
        syncStrategy: SyncStrategy,
        profilingConfig: TransportProfilingConfig?,
        outboundWriterMaxBytes: Int = TransportEnvConfig.defaultOutboundWriterMaxBytes
    ) {
        self.enableDirtyTracking = enableDirtyTracking
        self.useSnapshotForSync = useSnapshotForSync
        self.syncStrategy = syncStrategy
        self.profilingConfig = profilingConfig
        self.outboundWriterMaxBytes = outboundWriterMaxBytes
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
            profilingConfig: profilingConfig,
            outboundWriterMaxBytes: outboundWriterMaxBytes
        )
    }
}

/// The environment keys of the removed auto dirty switch and its change-object metric. A set
/// one is ignored; the first adapter in a process logs a warning naming every one that is set
/// (`shared`), so a deployment that still sets one isn't changed silently.
package final class TransportRemovedEnvKeys: @unchecked Sendable {
    package static let all = [
        "ENABLE_CHANGE_OBJECT_METRICS",
        "CHANGE_OBJECT_METRICS_LOG_EVERY",
        "CHANGE_OBJECT_METRICS_EMA_ALPHA",
        "AUTO_DIRTY_TRACKING",
        "AUTO_DIRTY_OFF_THRESHOLD",
        "AUTO_DIRTY_ON_THRESHOLD",
        "AUTO_DIRTY_REQUIRED_SAMPLES",
        "AUTO_DIRTY_SAMPLE_EVERY",
    ]

    /// This process's check, which the adapters share.
    static let shared = TransportRemovedEnvKeys(environment: ProcessInfo.processInfo.environment)

    private let lock = NSLock()
    private var pending: [String]?

    /// A check of `environment`.
    package init(environment: [String: String]) {
        pending = Self.all.filter { environment[$0] != nil }
    }

    /// The removed keys set in the environment, in `all`'s order, on the first call; empty
    /// after that, so the caller logs them once.
    package func takeFirst() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        defer { pending = nil }
        return pending ?? []
    }
}
