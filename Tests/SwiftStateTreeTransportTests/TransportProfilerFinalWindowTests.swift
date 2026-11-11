// Tests/SwiftStateTreeTransportTests/TransportProfilerFinalWindowTests.swift
//
// The profiler's final window (#351): the counters since the last line, written once as a line
// marked `"final": true` with its real length, so a reader can tell it from a full window.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@Suite("Transport profiler: final window")
struct TransportProfilerFinalWindowTests {
    @Test("flushFinalWindow writes the counters gathered since the last line, marked final with its length")
    func finalWindowLine() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("final-window-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let profiler = TransportProfilingActor.makeForTesting(config: TransportProfilingConfig(
            jsonlPath: path, intervalMs: 1000, sampleRate: 1, maxSamplesPerInterval: 100
        ))
        profiler.getCounters().incrementActions(by: 3)

        await profiler.flushFinalWindow()

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["final"] as? Bool == true)
        let interval = try #require(object["interval_ms"] as? Double)
        #expect(interval >= 0 && interval < 60_000)
        let counters = try #require(object["counters"] as? [String: Any])
        #expect(counters["actions"] as? Int == 3)
        // Taken: a later window starts from zero.
        #expect(profiler.getCounters().takeAndReset().actions == 0)
    }
}
