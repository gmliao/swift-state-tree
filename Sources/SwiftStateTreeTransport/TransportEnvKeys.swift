// Sources/SwiftStateTreeTransport/TransportEnvKeys.swift
//
// Environment variable keys for Transport and Profiling.

import Foundation

enum TransportEnvKeys {
    static let enableDirtyTracking = "ENABLE_DIRTY_TRACKING"
    static let useSnapshotForSync = "USE_SNAPSHOT_FOR_SYNC"
    static let enableChangeObjectMetrics = "ENABLE_CHANGE_OBJECT_METRICS"
    static let changeObjectMetricsLogEvery = "CHANGE_OBJECT_METRICS_LOG_EVERY"
    static let changeObjectMetricsEmaAlpha = "CHANGE_OBJECT_METRICS_EMA_ALPHA"
    static let autoDirtyTracking = "AUTO_DIRTY_TRACKING"
    static let autoDirtyOffThreshold = "AUTO_DIRTY_OFF_THRESHOLD"
    static let autoDirtyOnThreshold = "AUTO_DIRTY_ON_THRESHOLD"
    static let autoDirtyRequiredSamples = "AUTO_DIRTY_REQUIRED_SAMPLES"

    enum Profiling {
        static let jsonlPath = "TRANSPORT_PROFILE_JSONL_PATH"
        static let intervalMs = "TRANSPORT_PROFILE_INTERVAL_MS"
        static let sampleRate = "TRANSPORT_PROFILE_SAMPLE_RATE"
        static let maxSamplesPerInterval = "TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL"
    }
}
