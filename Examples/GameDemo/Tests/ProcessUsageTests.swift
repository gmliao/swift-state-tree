// Tests/ProcessUsageTests.swift
//
// Process CPU time and resident memory, as the load-test tools (ServerLoadTest, EncodingBenchmark)
// report them.

import Foundation
import LoadTestPacing
import Testing

@Suite("ProcessUsage")
struct ProcessUsageTests {
    @Test("CPU time is reported and grows with work")
    func cpuSecondsGrow() throws {
        let before = try #require(ProcessUsage.cpuSeconds())
        // Busy work until the process clock has moved by at least 20 ms of CPU, or 2 s of wall time.
        let deadline = Date().addingTimeInterval(2)
        var sink: UInt64 = 0
        while (ProcessUsage.cpuSeconds() ?? before) - before < 0.02, Date() < deadline {
            for i in 0 ..< 100_000 { sink = sink &* 31 &+ UInt64(i) }
        }
        let after = try #require(ProcessUsage.cpuSeconds())
        #expect(sink != 1)
        #expect(after - before >= 0.02)
    }

    @Test("Resident memory is reported, and the peak is at least the current value")
    func residentMemory() throws {
        let current = try #require(ProcessUsage.currentResidentBytes())
        let peak = try #require(ProcessUsage.peakResidentBytes())
        #expect(current > 0)
        #expect(peak >= current)
    }

    @Test("CPU percent over an interval")
    func cpuPercent() {
        #expect(ProcessUsage.cpuPercent(fromCPUSeconds: 1.0, toCPUSeconds: 2.5, wallSeconds: 1.0) == 150)
        #expect(ProcessUsage.cpuPercent(fromCPUSeconds: 1.0, toCPUSeconds: 1.0, wallSeconds: 2.0) == 0)
        #expect(ProcessUsage.cpuPercent(fromCPUSeconds: 1.0, toCPUSeconds: 2.0, wallSeconds: 0) == nil)
        #expect(ProcessUsage.cpuPercent(fromCPUSeconds: nil, toCPUSeconds: 2.0, wallSeconds: 1) == nil)
    }
}
