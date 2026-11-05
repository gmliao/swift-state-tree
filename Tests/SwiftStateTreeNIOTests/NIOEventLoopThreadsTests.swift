// Tests/SwiftStateTreeNIOTests/NIOEventLoopThreadsTests.swift
//
// The event-loop thread count (#150): by default the CPUs this process may use (its CPU affinity
// and cgroup quota, not every CPU on the machine), EVENT_LOOP_THREADS through EnvKeys, and an
// explicit value wins.

import Foundation
import NIOCore
import Testing
import SwiftStateTree
@testable import SwiftStateTreeNIO

@Suite("NIOWebSocketServerConfiguration: event-loop threads")
struct NIOEventLoopThreadsTests {

    @Test("The default follows the CPUs this process may use")
    func defaultFollowsAvailableCPUs() {
        let available = NIOWebSocketServerConfiguration.availableCPUCount
        #expect(available >= 1)
        // Never more than NIO's count (cgroup quota and cpuset) or the affinity mask, which
        // NIO's count does not read.
        let affinity: Int
        if case .cpus(let cpus) = NIOWebSocketServerConfiguration.readAffinityMask() {
            affinity = cpus
        } else {
            affinity = ProcessInfo.processInfo.activeProcessorCount
        }
        #expect(available == max(1, min(System.coreCount, affinity)))
        #expect(NIOWebSocketServerConfiguration.eventLoopThreads(environment: [:]) == available)
        // An explicit 0 or below gives availableCPUCount, not EVENT_LOOP_THREADS.
        #expect(NIOWebSocketServerConfiguration.normalizedEventLoopThreads(0) == available)
    }

    @Test("The CPU count reports its source, and a mask that does not parse is flagged")
    func cpuCountSource() throws {
        let missing = NIOWebSocketServerConfiguration.availableCPUs(statusPath: "/nonexistent/status")
        #expect(!missing.affinityMaskUnparsable)
        #expect(missing.source != .cpusAllowedList)
        #expect(missing.count == max(1, min(System.coreCount, ProcessInfo.processInfo.activeProcessorCount)))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sst-cpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = directory.appendingPathComponent("status")

        try "Name:\tx\nCpus_allowed_list:\t0,,2\n".write(to: status, atomically: true, encoding: .utf8)
        let broken = NIOWebSocketServerConfiguration.availableCPUs(statusPath: status.path)
        #expect(NIOWebSocketServerConfiguration.readAffinityMask(statusPath: status.path) == .unparsable)
        #expect(broken.affinityMaskUnparsable)
        #expect(broken.source != .cpusAllowedList)

        try "Name:\tx\nCpus_allowed_list:\t0\n".write(to: status, atomically: true, encoding: .utf8)
        let pinned = NIOWebSocketServerConfiguration.availableCPUs(statusPath: status.path)
        #expect(pinned == .init(count: 1, source: .cpusAllowedList, affinityMaskUnparsable: false))

        try "Name:\tx\nCpus_allowed_list:\t0-100000\n".write(to: status, atomically: true, encoding: .utf8)
        let wide = NIOWebSocketServerConfiguration.availableCPUs(statusPath: status.path)
        #expect(wide.source == .coreCount)
        #expect(wide.count == max(1, System.coreCount))
    }

    @Test("Cpus_allowed_list parses into a CPU count")
    func cpusAllowedListParses() {
        func count(_ list: String) -> Int? {
            NIOWebSocketServerConfiguration.cpusAllowedCount(status: "Name:\tGameServer\nCpus_allowed:\tff\nCpus_allowed_list:\t\(list)\nMems_allowed_list:\t0\n")
        }
        #expect(count("0-7") == 8)
        #expect(count("0") == 1)
        #expect(count("0-3,8,10-11") == 7)
        #expect(count("2,4,6") == 3)
        #expect(count("") == nil)
        #expect(count("3-1") == nil)
        #expect(count("a-b") == nil)
        // Empty pieces and extra dashes.
        #expect(count("0,,2") == nil)
        #expect(count("-3") == nil)
        #expect(count("3-") == nil)
        #expect(count("0,") == nil)
        #expect(count("1-2-3") == nil)
        // A count that overflows is rejected, not trapped on.
        #expect(count("0-\(Int.max)") == nil)
        #expect(count("0-\(Int.max - 1),\(Int.max)") == nil)
        #expect(NIOWebSocketServerConfiguration.cpusAllowedCount(status: "Name:\tx\n") == nil)
        #expect(NIOWebSocketServerConfiguration.readAffinityMask(statusPath: "/nonexistent/status") == .unavailable)
    }

    #if os(Linux)
    // Linux only: the affinity mask is what a `taskset` pin changes, and only Linux has it in
    // /proc. This checks the default against the mask of this very process, and that the mask
    // is read at all (a parse failure would silently fall back to activeProcessorCount).
    @Test("On Linux the default follows this process's affinity mask")
    func linuxDefaultFollowsAffinityMask() throws {
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        let allowed = try #require(NIOWebSocketServerConfiguration.cpusAllowedCount(status: status), "Cpus_allowed_list did not parse")
        #expect(NIOWebSocketServerConfiguration.readAffinityMask() == .cpus(allowed))
        #expect(NIOWebSocketServerConfiguration.availableCPUs().affinityMaskUnparsable == false)
        #expect(NIOWebSocketServerConfiguration.availableCPUCount == max(1, min(System.coreCount, allowed)))
    }

    @Test("On Linux a taskset pin shows up in the parsed mask")
    func linuxTasksetPinIsParsed() throws {
        let taskset = ["/usr/bin/taskset", "/bin/taskset"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let taskset else { return }  // util-linux missing: nothing to pin with
        let process = Process()
        process.executableURL = URL(fileURLWithPath: taskset)
        // Pin to the first CPU this process may use: CPU 0 is not always allowed (cpuset 8-15).
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        let list = try #require(status.split(separator: "\n").first { $0.hasPrefix("Cpus_allowed_list:") })
        let firstCPU = try #require(Int(list.dropFirst("Cpus_allowed_list:".count)
            .trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }))
        process.arguments = ["-c", String(firstCPU), "cat", "/proc/self/status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        #expect(NIOWebSocketServerConfiguration.cpusAllowedCount(status: String(decoding: output, as: UTF8.self)) == 1)
    }
    #endif

    @Test("EVENT_LOOP_THREADS unset or invalid gives the default")
    func invalidEnvironmentGivesDefault() {
        let available = NIOWebSocketServerConfiguration.availableCPUCount
        for raw in ["", "abc", "0", "-3", "2.5"] {
            #expect(
                NIOWebSocketServerConfiguration.eventLoopThreads(environment: [EnvKeys.Server.eventLoopThreads: raw]) == available,
                "EVENT_LOOP_THREADS=\(raw)"
            )
        }
    }

    @Test("EVENT_LOOP_THREADS sets the count, even above the CPU count")
    func environmentOverride() {
        #expect(NIOWebSocketServerConfiguration.eventLoopThreads(environment: [EnvKeys.Server.eventLoopThreads: "1"]) == 1)
        #expect(NIOWebSocketServerConfiguration.eventLoopThreads(environment: [EnvKeys.Server.eventLoopThreads: " 8 "]) == 8)
        #expect(NIOWebSocketServerConfiguration.eventLoopThreads(environment: [EnvKeys.Server.eventLoopThreads: "64"]) == 64)
    }

    @Test("An explicit eventLoopThreads wins; 0 or below gives the default")
    func explicitValue() {
        let available = NIOWebSocketServerConfiguration.availableCPUCount
        #expect(NIOWebSocketServerConfiguration(eventLoopThreads: 3).eventLoopThreads == 3)
        #expect(NIOWebSocketServerConfiguration(eventLoopThreads: 0).eventLoopThreads == available)
        #expect(NIOLandHostConfiguration(eventLoopThreads: 2).eventLoopThreads == 2)
        #expect(NIOLandHostConfiguration(eventLoopThreads: 2).webSocketServerConfiguration().eventLoopThreads == 2)
    }
}
