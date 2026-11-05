// Examples/GameDemo/Sources/EncodingBenchmark/ProcessMemory.swift
//
// Process resident set size (RSS), for the benchmark's memory report.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Resident memory of this process, in bytes.
///
/// Foundation has no RSS API, so this is the one place the benchmark branches by platform:
/// `getrusage` gives the peak on both (in bytes on Darwin, in KiB on Linux), and the current
/// value comes from `task_info` on Darwin and `/proc/self/statm` on Linux.
enum ProcessMemory {
    /// Peak RSS since the process started; nil if the platform does not report it.
    static func peakResidentBytes() -> UInt64? {
        var usage = rusage()
        #if canImport(Darwin)
        let who = RUSAGE_SELF
        #else
        // Glibc imports RUSAGE_SELF as an enum case; getrusage takes its raw value.
        let who = __rusage_who_t(RUSAGE_SELF.rawValue)
        #endif
        guard getrusage(who, &usage) == 0, usage.ru_maxrss > 0 else { return nil }
        #if canImport(Darwin)
        return UInt64(usage.ru_maxrss)
        #else
        return UInt64(usage.ru_maxrss) * 1024
        #endif
    }

    /// Current RSS; nil if the platform does not report it.
    static func currentResidentBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
        #else
        // statm: total and resident sizes, in pages.
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return nil }
        let fields = statm.split(separator: " ")
        guard fields.count > 1, let pages = UInt64(fields[1]) else { return nil }
        return pages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
        #endif
    }

    /// Both values in MiB, for JSON output (nil values are left out).
    static func report() -> [String: Double] {
        var report: [String: Double] = [:]
        if let peak = peakResidentBytes() { report["peakRSSMiB"] = Double(peak) / 1_048_576 }
        if let current = currentResidentBytes() { report["endRSSMiB"] = Double(current) / 1_048_576 }
        return report
    }
}
