// Sources/SwiftStateTreeTransport/TransportEnvKeys.swift
//
// Environment variable keys for Transport and Profiling.

import Foundation
import SwiftStateTree

enum TransportEnvKeys {
    static let enableDirtyTracking = "ENABLE_DIRTY_TRACKING"
    static let useSnapshotForSync = "USE_SNAPSHOT_FOR_SYNC"
    static let useSyncTables = "USE_SYNC_TABLES"
    static let syncStrategy = SyncStrategy.environmentKey
    static let enableChangeObjectMetrics = "ENABLE_CHANGE_OBJECT_METRICS"
    static let changeObjectMetricsLogEvery = "CHANGE_OBJECT_METRICS_LOG_EVERY"
    static let changeObjectMetricsEmaAlpha = "CHANGE_OBJECT_METRICS_EMA_ALPHA"
    static let autoDirtyTracking = "AUTO_DIRTY_TRACKING"
    static let autoDirtyOffThreshold = "AUTO_DIRTY_OFF_THRESHOLD"
    static let autoDirtyOnThreshold = "AUTO_DIRTY_ON_THRESHOLD"
    static let autoDirtyRequiredSamples = "AUTO_DIRTY_REQUIRED_SAMPLES"
    static let autoDirtySampleEvery = "AUTO_DIRTY_SAMPLE_EVERY"
    static let outboundWriterMaxBytes = "OUTBOUND_WRITER_MAX_BYTES"
    /// `TransportEncodingConfig.pathIndex` (default true).
    static let pathIndex = "PATH_INDEX"
    /// `TransportEncodingConfig.fieldMerge` (default true).
    static let fieldMerge = "FIELD_MERGE"
    /// `TransportEncodingConfig.dynamicKeyCompression` (default true).
    static let dynamicKeyCompression = "DYNAMIC_KEY_COMPRESSION"
    /// Ready joins flipped per committed sync phase at most (#69; default 64).
    static let joinFlipBudget = "JOIN_FLIP_BUDGET"
    /// The end-to-end join budget, ms, from the join request (#104; default 12000, 0 disables).
    static let joinTimeoutMs = "JOIN_TIMEOUT_MS"
    /// `SyncLagPolicy` thresholds (#332), ms or a count; see `SyncLagPolicy.fromEnvironment`.
    static let syncLagResyncMs = "SYNC_LAG_RESYNC_MS"
    static let syncLagSlowConsumerCount = "SYNC_LAG_SLOW_CONSUMER_COUNT"
    static let syncLagSlowConsumerWindowMs = "SYNC_LAG_SLOW_CONSUMER_WINDOW_MS"
    static let syncAckTimeoutMs = "SYNC_ACK_TIMEOUT_MS"
    static let syncAckFreshnessMs = "SYNC_ACK_FRESHNESS_MS"
    /// The terminal lag closes' close grace, ms (#339; default 2000, 0 turns it off).
    static let syncLagCloseGraceMs = "SYNC_LAG_CLOSE_GRACE_MS"
    /// Deprecated (#104): use `JOIN_TIMEOUT_MS`. When set, it still caps an in-turn join's
    /// flip wait, inside the join budget.
    static let joinFlipTimeoutMs = "JOIN_FLIP_TIMEOUT_MS"
    /// Targeted events held per joining session at most (#69; default 256).
    static let joinHeldEventsMax = "JOIN_HELD_EVENTS_MAX"
    /// Bytes of targeted events held per joining session at most (#69; default 262144).
    static let joinHeldEventsMaxBytes = "JOIN_HELD_EVENTS_MAX_BYTES"
    /// Inbound frames deferred per joining session at most (#69; default 256).
    static let joinDeferredInboundMax = "JOIN_DEFERRED_INBOUND_MAX"
    /// Bytes of inbound frames deferred per joining session at most (#69; default 262144).
    static let joinDeferredInboundMaxBytes = "JOIN_DEFERRED_INBOUND_MAX_BYTES"
    /// How long a closing error frame may take to be handed to the connection before the
    /// session is closed anyway, ms (default 1000).
    static let finalFrameCloseTimeoutMs = "FINAL_FRAME_CLOSE_TIMEOUT_MS"
    /// A file for the land lifecycle log (`LandLifecycleLog`): one JSON line per land instance
    /// created, removed by ID or destroyed. Unset (the default): no log.
    static let landLifecycleLogPath = "LAND_LIFECYCLE_LOG_PATH"

    enum Profiling {
        static let jsonlPath = "TRANSPORT_PROFILE_JSONL_PATH"
        static let intervalMs = "TRANSPORT_PROFILE_INTERVAL_MS"
        static let sampleRate = "TRANSPORT_PROFILE_SAMPLE_RATE"
        static let maxSamplesPerInterval = "TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL"
    }
}

/// Limits of joins that complete in a turn (#69), read once from the environment.
enum JoinFlipConfig {
    /// Ready joins flipped per committed sync phase at most (`JOIN_FLIP_BUDGET`, default 64).
    static let budget = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinFlipBudget, defaultValue: 64))
    /// Targeted events held for a joining session until its flip, at most
    /// (`JOIN_HELD_EVENTS_MAX`, default 256). Over it, the join fails with `eventOverflow`.
    static let heldEventsMax = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinHeldEventsMax, defaultValue: 256))
    /// Encoded bytes of the targeted events held for a joining session, at most
    /// (`JOIN_HELD_EVENTS_MAX_BYTES`, default 256 KiB).
    static let heldEventsMaxBytes = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinHeldEventsMaxBytes, defaultValue: 256 * 1024))
    /// Inbound frames of a joining session deferred until after its flip, at most
    /// (`JOIN_DEFERRED_INBOUND_MAX`, default 256). Over it, the join fails with
    /// `inboundOverflow`; after the flip, the session is closed.
    static let deferredInboundMax = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinDeferredInboundMax, defaultValue: 256))
    /// Bytes of a joining session's deferred inbound frames, at most
    /// (`JOIN_DEFERRED_INBOUND_MAX_BYTES`, default 256 KiB).
    static let deferredInboundMaxBytes = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinDeferredInboundMaxBytes, defaultValue: 256 * 1024))
    /// How long a closing error frame may wait to be handed to the connection before the
    /// session is closed anyway (`FINAL_FRAME_CLOSE_TIMEOUT_MS`, default 1 s).
    static let finalFrameCloseTimeout = Duration.milliseconds(max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.finalFrameCloseTimeoutMs, defaultValue: 1000)))
}

/// Why a join that completes in a turn (#69) failed before its flip.
public enum JoinFlipError: Error, Sendable, Hashable {
    /// A newer join of the same player was admitted (newest wins, #92).
    case superseded
    /// The session disconnected.
    case disconnected
    /// The land was torn down.
    case landClosed
    /// OnJoin threw: the keeper removed the join's input and player.
    case onJoinFailed
    /// No committed sync phase flipped it within the join flip timeout.
    case timeout
    /// More targeted events were held for the session than `JoinFlipConfig.heldEventsMax` or
    /// `heldEventsMaxBytes` allow.
    case eventOverflow
    /// More inbound frames arrived from the session before its flip than
    /// `JoinFlipConfig.deferredInboundMax` or `deferredInboundMaxBytes` allow.
    case inboundOverflow
}
