// Tests/SwiftStateTreeTests/ReplayRecordRefusalTests.swift
//
// A malformed record fails its replay run, and the process goes on (#639, #640).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

/// A 2.6 JSON record with one empty frame per tick ID, in that order.
private func jsonRecord(tickIds: [Int64]) -> Data {
    let frames = tickIds
        .map { #"{"tickId":\#($0),"actions":[],"clientEvents":[],"lifecycleEvents":[]}"# }
        .joined(separator: ",")
    let text = #"{"recordMetadata":{"landID":"l","landType":"record-refusal","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"2.6"},"tickFrames":["#
        + frames + "]}"
    return Data(text.utf8)
}

private func tempRecordPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("record-refusal-\(UUID().uuidString).json").path
}

/// Opens the record the run names, as the admin start's factory does, and replays nothing.
private struct OpeningFactory: ReevaluationTargetFactory {
    func createRunner(landType _: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        _ = try ReevaluationRecordFile.openSource(filePath: recordFilePath)
        return FixedTickRunner(maxTickId: -1)
    }
}

/// A custom runner that reports `maxTickId` and has no tick to step.
private actor FixedTickRunner: ReevaluationRunnerProtocol {
    nonisolated let maxTickId: Int64
    private(set) var stepCalls = 0

    init(maxTickId: Int64) { self.maxTickId = maxTickId }

    func prepare() async throws {}

    func step() async throws -> ReevaluationStepResult? {
        stepCalls += 1
        return nil
    }
}

private struct FixedFactory: ReevaluationTargetFactory {
    let runner: FixedTickRunner
    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol { runner }
}

/// Waits for the service's run to end, by awaiting its task, and returns the terminal status.
private func terminalStatus(of service: ReevaluationRunnerService) async throws -> ReevaluationStatus {
    let task = try #require(service.verificationTaskForTesting(), "no verification run was started")
    await task.value
    return service.getStatus()
}

@Suite("ReplayRecordRefusalTests", .timeLimit(.minutes(1)))
struct ReplayRecordRefusalTests {
    @Test("A JSON record with two frames for one tick is refused at open, naming the tick (#639)")
    func duplicateTickIsRefused() throws {
        #expect(throws: ReevaluationRecordContentError.duplicateTickId(3)) {
            _ = try JSONReevaluationSource(data: jsonRecord(tickIds: [0, 3, 1, 3]))
        }
        #expect(throws: ReevaluationRecordContentError.duplicateTickId(3)) {
            _ = try ReevaluationRecordFile.openSource(data: jsonRecord(tickIds: [0, 3, 1, 3]))
        }
    }

    @Test("A tick outside 0 ..< Int64.max is refused at open; the first bad frame is named (#640)")
    func outOfRangeTickIsRefused() throws {
        #expect(throws: ReevaluationRecordContentError.tickIdOutOfRange(Int64.max)) {
            _ = try JSONReevaluationSource(data: jsonRecord(tickIds: [0, Int64.max]))
        }
        #expect(throws: ReevaluationRecordContentError.tickIdOutOfRange(-1)) {
            _ = try JSONReevaluationSource(data: jsonRecord(tickIds: [0, -1, 0]))
        }
    }

    @Test("The last tick a live run can write still opens (#640)")
    func lastWritableTickOpens() async throws {
        let source = try JSONReevaluationSource(data: jsonRecord(tickIds: [0, Int64.max - 1]))
        #expect(try await source.getMaxTickId() == Int64.max - 1)
    }

    @Test("A run whose record holds a duplicate tick fails with the tick; the service takes the next run (#639)")
    func duplicateTickFailsTheRun() async throws {
        let path = tempRecordPath()
        try jsonRecord(tickIds: [0, 3, 3]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let service = ReevaluationRunnerService(factory: OpeningFactory())
        service.startVerification(landType: "record-refusal", recordFilePath: path)
        let failed = try await terminalStatus(of: service)
        #expect(failed.phase == .failed)
        #expect(failed.errorMessage.contains("tick 3"), "\(failed.errorMessage)")

        let good = tempRecordPath()
        try jsonRecord(tickIds: [0, 1]).write(to: URL(fileURLWithPath: good))
        defer { try? FileManager.default.removeItem(atPath: good) }
        service.startVerification(landType: "record-refusal", recordFilePath: good)
        #expect(try await terminalStatus(of: service).phase == .completed)
    }

    @Test("A custom runner whose last tick is Int64.max fails the run before its first step (#640)")
    func runnerTickCountOverflowFailsTheRun() async throws {
        let runner = FixedTickRunner(maxTickId: Int64.max)
        let service = ReevaluationRunnerService(factory: FixedFactory(runner: runner))
        service.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let status = try await terminalStatus(of: service)
        #expect(status.phase == .failed)
        #expect(status.errorMessage.contains("\(Int64.max)"), "\(status.errorMessage)")
        #expect(await runner.stepCalls == 0)
    }

    @Test("A custom runner one tick below the overflow still runs (#640)")
    func runnerTickCountAtTheBoundRuns() async throws {
        let runner = FixedTickRunner(maxTickId: Int64.max - 1)
        let service = ReevaluationRunnerService(factory: FixedFactory(runner: runner))
        service.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let status = try await terminalStatus(of: service)
        #expect(status.phase == .completed)
        #expect(status.totalTicks == Int64.max)
    }
}
