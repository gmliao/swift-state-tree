// Sources/LoadTestPacing/ProcessUsage.swift
//
// Process CPU time and resident set size (RSS), for the load-test tools' reports
// (ServerLoadTest's per-second samples, EncodingBenchmark's timing and memory).

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// CPU time and resident memory of this process.
///
/// Foundation has no API for either, so this is the one place the load-test tools branch by
/// platform:
/// - CPU time and peak RSS come from `getrusage` on both (peak RSS in bytes on Darwin, in KiB on
///   Linux);
/// - current RSS comes from `task_info` on Darwin and `/proc/self/statm` on Linux.
public enum ProcessUsage {
    /// User plus system CPU time of all the process's threads since it started, in seconds;
    /// nil if the platform does not report it.
    public static func cpuSeconds() -> Double? {
        guard let usage = selfUsage() else { return nil }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Peak RSS since the process started; nil if the platform does not report it.
    public static func peakResidentBytes() -> UInt64? {
        guard let usage = selfUsage(), usage.ru_maxrss > 0 else { return nil }
        #if canImport(Darwin)
        return UInt64(usage.ru_maxrss)
        #else
        return UInt64(usage.ru_maxrss) * 1024
        #endif
    }

    /// Current RSS; nil if the platform does not report it.
    public static func currentResidentBytes() -> UInt64? {
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

    /// CPU use over an interval, in percent of one core (200 = two cores busy); nil when either
    /// reading is missing or the interval is empty.
    public static func cpuPercent(fromCPUSeconds start: Double?, toCPUSeconds end: Double?, wallSeconds: Double) -> Double? {
        guard let start, let end, wallSeconds > 0 else { return nil }
        return (end - start) * 100 / wallSeconds
    }

    private static func selfUsage() -> rusage? {
        var usage = rusage()
        #if canImport(Darwin)
        let who = RUSAGE_SELF
        #else
        // Glibc imports RUSAGE_SELF as an enum case; getrusage takes its raw value.
        let who = __rusage_who_t(RUSAGE_SELF.rawValue)
        #endif
        guard getrusage(who, &usage) == 0 else { return nil }
        return usage
    }

    private static func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
