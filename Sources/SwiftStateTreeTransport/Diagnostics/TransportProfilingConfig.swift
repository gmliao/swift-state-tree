// Sources/SwiftStateTreeTransport/Diagnostics/TransportProfilingConfig.swift
//
// Configuration for TransportProfilingActor, read from environment variables.

import Foundation

/// Configuration for transport profiling. Read from environment when enabled.
public struct TransportProfilingConfig: Sendable {
    /// Output path for JSONL. Profiling is disabled when nil.
    let jsonlPath: String?
    /// Interval between JSONL writes in milliseconds.
    let intervalMs: Int
    /// Sample rate for latency (0.0–1.0). 0.01 = 1%.
    let sampleRate: Double
    /// Max latency samples per interval per segment to avoid OOM.
    let maxSamplesPerInterval: Int

    /// Create config from environment. Returns nil (disabled) when TRANSPORT_PROFILE_JSONL_PATH is not set.
    static func fromEnvironment() -> TransportProfilingConfig? {
        guard let path = ProcessInfo.processInfo.environment["TRANSPORT_PROFILE_JSONL_PATH"],
              !path.isEmpty
        else {
            return nil
        }
        let intervalMs = Int(ProcessInfo.processInfo.environment["TRANSPORT_PROFILE_INTERVAL_MS"] ?? "1000") ?? 1000
        let sampleRate = Double(ProcessInfo.processInfo.environment["TRANSPORT_PROFILE_SAMPLE_RATE"] ?? "0.01") ?? 0.01
        let maxSamples = Int(ProcessInfo.processInfo.environment["TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL"] ?? "500") ?? 500
        return TransportProfilingConfig(
            jsonlPath: path,
            intervalMs: max(100, intervalMs),
            sampleRate: min(1.0, max(0.001, sampleRate)),
            maxSamplesPerInterval: max(10, min(10_000, maxSamples))
        )
    }

    /// Whether profiling is enabled.
    var isEnabled: Bool { jsonlPath != nil }
}
