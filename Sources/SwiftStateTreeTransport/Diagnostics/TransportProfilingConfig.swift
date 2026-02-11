// Sources/SwiftStateTreeTransport/Diagnostics/TransportProfilingConfig.swift
//
// Configuration for TransportProfilingActor, read from environment variables.

import Foundation
import SwiftStateTree

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
    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TransportProfilingConfig? {
        guard let path = EnvHelpers.getEnvStringOptional(key: TransportEnvKeys.Profiling.jsonlPath, environment: environment),
              !path.isEmpty
        else {
            return nil
        }
        let intervalMs = max(100, EnvHelpers.getEnvInt(key: TransportEnvKeys.Profiling.intervalMs, defaultValue: 1000, environment: environment))
        let sampleRate = EnvHelpers.getEnvDouble(
            key: TransportEnvKeys.Profiling.sampleRate,
            defaultValue: 0.01,
            min: 0.001,
            max: 1.0,
            environment: environment
        )
        let maxSamples = EnvHelpers.getEnvInt(key: TransportEnvKeys.Profiling.maxSamplesPerInterval, defaultValue: 500, environment: environment)
        let clampedMaxSamples = max(10, min(10_000, maxSamples))
        return TransportProfilingConfig(
            jsonlPath: path,
            intervalMs: intervalMs,
            sampleRate: sampleRate,
            maxSamplesPerInterval: clampedMaxSamples
        )
    }

    /// Whether profiling is enabled.
    var isEnabled: Bool { jsonlPath != nil }
}
