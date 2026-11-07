// Examples/GameDemo/Sources/EncodingBenchmark/ProcessMemory.swift
//
// Process resident set size (RSS), for the benchmark's memory report. The platform code is in
// LoadTestPacing's ProcessUsage, shared with ServerLoadTest.

import Foundation
import LoadTestPacing

enum ProcessMemory {
    /// Peak and current RSS in MiB, for JSON output (nil values are left out).
    static func report() -> [String: Double] {
        var report: [String: Double] = [:]
        if let peak = ProcessUsage.peakResidentBytes() { report["peakRSSMiB"] = Double(peak) / 1_048_576 }
        if let current = ProcessUsage.currentResidentBytes() { report["endRSSMiB"] = Double(current) / 1_048_576 }
        return report
    }
}
