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

/// A custom runner that reports `maxTickId` but steps `steps` times before it ends, so a runner that
/// reports less than it steps ends on its own when no bound stops it.
private actor SteppingRunner: ReevaluationRunnerProtocol {
    nonisolated let maxTickId: Int64
    private let steps: Int
    private(set) var stepCalls = 0

    init(maxTickId: Int64, steps: Int) {
        self.maxTickId = maxTickId
        self.steps = steps
    }

    func prepare() async throws {}

    func step() async throws -> ReevaluationStepResult? {
        stepCalls += 1
        guard stepCalls <= steps else { return nil }
        return ReevaluationStepResult(tickId: Int64(stepCalls - 1), stateHash: "h", recordedHash: "h", isMatch: true)
    }
}

private struct SteppingFactory: ReevaluationTargetFactory {
    let runner: SteppingRunner
    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol { runner }
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
        // The run length bound (#728) is lifted: the tick range is what this test pins.
        let source = try JSONReevaluationSource(data: jsonRecord(tickIds: [0, Int64.max - 1]), maxReplayTicks: Int64.max)
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
        let service = ReevaluationRunnerService(factory: FixedFactory(runner: runner), maxReplayTicks: Int64.max)
        service.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let status = try await terminalStatus(of: service)
        #expect(status.phase == .completed)
        #expect(status.totalTicks == Int64.max)
    }

    @Test("A custom runner past the service's default limit fails the run before its first step (#728)")
    func runnerPastTheDefaultLimitFailsTheRun() async throws {
        let limit = ReevaluationRecordFile.defaultMaxReplayTicks
        let atLimit = FixedTickRunner(maxTickId: limit - 1)
        let okService = ReevaluationRunnerService(factory: FixedFactory(runner: atLimit))
        okService.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let ok = try await terminalStatus(of: okService)
        #expect(ok.phase == .completed)
        #expect(ok.totalTicks == limit)

        let past = FixedTickRunner(maxTickId: limit)
        let service = ReevaluationRunnerService(factory: FixedFactory(runner: past))
        service.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let status = try await terminalStatus(of: service)
        #expect(status.phase == .failed)
        #expect(
            status.errorMessage == ReevaluationRecordContentError.replayTooLong(lastTick: limit, limit: limit).description,
            "\(status.errorMessage)"
        )
        #expect(await past.stepCalls == 0)
    }

    @Test("A smaller limit on the service is honored: at the limit the run goes on, one past it fails before its first step (#728)")
    func serviceLimitIsHonored() async throws {
        let atLimit = FixedTickRunner(maxTickId: 99)
        let okService = ReevaluationRunnerService(factory: FixedFactory(runner: atLimit), maxReplayTicks: 100)
        okService.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        #expect(try await terminalStatus(of: okService).phase == .completed)

        let past = FixedTickRunner(maxTickId: 100)
        let service = ReevaluationRunnerService(factory: FixedFactory(runner: past), maxReplayTicks: 100)
        service.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let status = try await terminalStatus(of: service)
        #expect(status.phase == .failed)
        #expect(status.errorMessage.contains("100"), "\(status.errorMessage)")
        #expect(await past.stepCalls == 0)
    }

    @Test("A run whose record is past the default limit fails with the typed error, and the service takes the next run (#728)")
    func longRecordFailsTheRun() async throws {
        let path = tempRecordPath()
        try jsonRecord(tickIds: [0, 1_000_000_000_000]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let service = ReevaluationRunnerService(factory: OpeningFactory())
        service.startVerification(landType: "record-refusal", recordFilePath: path)
        let failed = try await terminalStatus(of: service)
        #expect(failed.phase == .failed)
        #expect(failed.errorMessage.contains("1000000000000"), "\(failed.errorMessage)")

        let good = tempRecordPath()
        try jsonRecord(tickIds: [0, 1]).write(to: URL(fileURLWithPath: good))
        defer { try? FileManager.default.removeItem(atPath: good) }
        service.startVerification(landType: "record-refusal", recordFilePath: good)
        #expect(try await terminalStatus(of: service).phase == .completed)
    }

    @Test("A runner that steps more often than the limit fails the run when it passes it, whatever maxTickId it reported (#728)")
    func underReportingRunnerIsBounded() async throws {
        // It reports 2 ticks and would take 20 steps; the service's limit is 5.
        let runner = SteppingRunner(maxTickId: 1, steps: 20)
        let service = ReevaluationRunnerService(factory: SteppingFactory(runner: runner), maxReplayTicks: 5)
        service.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let status = try await terminalStatus(of: service)
        #expect(status.phase == .failed)
        // The message states the result count the service measured, not a record tick.
        #expect(
            status.errorMessage == "the runner produced more than 5 results; a replay accepts at most 5",
            "\(status.errorMessage)"
        )
        // The result that trips the cap has been stepped: one step past the limit.
        #expect(await runner.stepCalls == 6)

        // A runner that takes exactly the limit completes.
        let exact = SteppingRunner(maxTickId: 1, steps: 5)
        let okService = ReevaluationRunnerService(factory: SteppingFactory(runner: exact), maxReplayTicks: 5)
        okService.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        #expect(try await terminalStatus(of: okService).phase == .completed)
    }

    @Test("A runner that reports a last tick below -1 fails the run before its first step, and -1 (no tick) still runs (#728)")
    func runnerLastTickBelowMinusOne() async throws {
        let below = FixedTickRunner(maxTickId: -2)
        let service = ReevaluationRunnerService(factory: FixedFactory(runner: below))
        service.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let status = try await terminalStatus(of: service)
        #expect(status.phase == .failed)
        #expect(status.errorMessage.contains("-2"), "\(status.errorMessage)")
        #expect(await below.stepCalls == 0)

        let none = FixedTickRunner(maxTickId: -1)
        let okService = ReevaluationRunnerService(factory: FixedFactory(runner: none))
        okService.startVerification(landType: "record-refusal", recordFilePath: "/unused")
        let ok = try await terminalStatus(of: okService)
        #expect(ok.phase == .completed)
        #expect(ok.totalTicks == 0)
    }
}
