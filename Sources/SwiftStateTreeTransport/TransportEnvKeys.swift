// Sources/SwiftStateTreeTransport/TransportEnvKeys.swift
//
// Environment variable keys for Transport and Profiling.

import Foundation
import SwiftStateTree

enum TransportEnvKeys {
    static let enableDirtyTracking = "ENABLE_DIRTY_TRACKING"
    static let useSnapshotForSync = "USE_SNAPSHOT_FOR_SYNC"
    static let syncStrategy = SyncStrategy.environmentKey
    static let enableChangeObjectMetrics = "ENABLE_CHANGE_OBJECT_METRICS"
    static let changeObjectMetricsLogEvery = "CHANGE_OBJECT_METRICS_LOG_EVERY"
    static let changeObjectMetricsEmaAlpha = "CHANGE_OBJECT_METRICS_EMA_ALPHA"
    static let autoDirtyTracking = "AUTO_DIRTY_TRACKING"
    static let autoDirtyOffThreshold = "AUTO_DIRTY_OFF_THRESHOLD"
    static let autoDirtyOnThreshold = "AUTO_DIRTY_ON_THRESHOLD"
    static let autoDirtyRequiredSamples = "AUTO_DIRTY_REQUIRED_SAMPLES"
    static let outboundWriterMaxBytes = "OUTBOUND_WRITER_MAX_BYTES"
    /// `TransportEncodingConfig.dynamicKeyCompression` (default true).
    static let dynamicKeyCompression = "DYNAMIC_KEY_COMPRESSION"
    /// Ready joins flipped per committed sync phase at most (#69; default 64).
    static let joinFlipBudget = "JOIN_FLIP_BUDGET"
    /// How long an in-turn join waits for its flip, ms (#69; default 10000).
    static let joinFlipTimeoutMs = "JOIN_FLIP_TIMEOUT_MS"
    /// Targeted events held per joining session at most (#69; default 256).
    static let joinHeldEventsMax = "JOIN_HELD_EVENTS_MAX"
    /// Bytes of targeted events held per joining session at most (#69; default 262144).
    static let joinHeldEventsMaxBytes = "JOIN_HELD_EVENTS_MAX_BYTES"

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
    /// How long a join waits for its flip before it fails with `timeout`
    /// (`JOIN_FLIP_TIMEOUT_MS`, default 10 s).
    static let timeout = Duration.milliseconds(max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinFlipTimeoutMs, defaultValue: 10_000)))
    /// Targeted events held for a joining session until its flip, at most
    /// (`JOIN_HELD_EVENTS_MAX`, default 256). Over it, the join fails with `eventOverflow`.
    static let heldEventsMax = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinHeldEventsMax, defaultValue: 256))
    /// Encoded bytes of the targeted events held for a joining session, at most
    /// (`JOIN_HELD_EVENTS_MAX_BYTES`, default 256 KiB).
    static let heldEventsMaxBytes = max(1, EnvHelpers.getEnvInt(key: TransportEnvKeys.joinHeldEventsMaxBytes, defaultValue: 256 * 1024))
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
}
