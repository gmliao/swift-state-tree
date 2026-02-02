// Sources/SwiftStateTreeTransport/Diagnostics/LatencySampler.swift
//
// Low-overhead latency sampling with capped buffer and percentile computation.
// Used by TransportProfilingActor for decode/handle/encode/send latency metrics.

import Foundation

/// Capped buffer for latency samples (milliseconds) with percentile computation.
/// Not thread-safe; use from a single actor.
struct LatencySampler: Sendable {
    private var samples: [Double] = []
    private let maxSamples: Int

    init(maxSamples: Int = 500) {
        self.maxSamples = max(maxSamples, 1)
    }

    /// Add a sample. Drops oldest if at capacity.
    mutating func add(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        if samples.count >= maxSamples {
            samples.removeFirst()
        }
        samples.append(ms)
    }

    /// Compute percentiles and return summary. Clears samples after.
    mutating func flush() -> LatencyPercentiles {
        guard !samples.isEmpty else {
            return LatencyPercentiles(p50: nil, p95: nil, p99: nil, max: nil, count: 0)
        }
        let sorted = samples.sorted()
        let count = sorted.count
        let p50 = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        let p99 = percentile(sorted, 0.99)
        let maxVal = sorted.last
        samples.removeAll(keepingCapacity: true)
        return LatencyPercentiles(
            p50: p50,
            p95: p95,
            p99: p99,
            max: maxVal,
            count: count
        )
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int(Double(sorted.count) * p)
        let i = min(index, sorted.count - 1)
        return sorted[i]
    }
}

/// Latency percentile summary for JSONL output.
struct LatencyPercentiles: Sendable {
    let p50: Double?
    let p95: Double?
    let p99: Double?
    let max: Double?
    let count: Int

    func toJSONObject() -> [String: Any] {
        var obj: [String: Any] = ["n": count]
        if let p50 { obj["p50_ms"] = rounded(p50) }
        if let p95 { obj["p95_ms"] = rounded(p95) }
        if let p99 { obj["p99_ms"] = rounded(p99) }
        if let max { obj["max_ms"] = rounded(max) }
        return obj
    }

    private func rounded(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }
}
