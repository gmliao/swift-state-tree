// Sources/SwiftStateTreeBenchmarks/BenchmarkEnvConfig.swift
//
// Benchmark-related environment configuration.
//
// Environment variables:
//
// | Key | Type | Default |
// |-----|------|---------|
// | DIFF_BENCHMARK_MODE | standard/optimized/both | both |

import Foundation
import SwiftStateTree

/// Benchmark environment configuration.
public struct BenchmarkEnvConfig: Sendable {
    /// Diff benchmark mode: standard (no dirty tracking), optimized (with dirty tracking), or both.
    public enum DiffBenchmarkMode: String, Sendable {
        case standard = "standard"
        case optimized = "optimized"
        case both = "both"
    }

    /// Mode for diff benchmark.
    public let diffBenchmarkMode: DiffBenchmarkMode

    /// Create config from environment.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BenchmarkEnvConfig {
        let raw = EnvHelpers.getEnvString(
            key: BenchmarkEnvKeys.diffBenchmarkMode,
            defaultValue: "both",
            environment: environment
        ).lowercased()
        let mode = DiffBenchmarkMode(rawValue: raw) ?? .both
        return BenchmarkEnvConfig(diffBenchmarkMode: mode)
    }
}
