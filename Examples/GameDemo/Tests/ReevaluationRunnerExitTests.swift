// Tests/ReevaluationRunnerExitTests.swift
//
// `ReevaluationRunner --verify` refuses a record by its schema fingerprint before the first step
// (#521 D15): exit 10 for a record without one, 13 for one of another schema. `--convert` and
// `--time-open` refuse a record past `--max-replay-ticks` like a replay does (#728): exit 14, and
// nothing is written. Runs the runner from the same build products as this test bundle, and kills
// it if it doesn't exit in time.

import Foundation
import SwiftStateTree
import Testing

@Suite("ReevaluationRunner exit codes for the record schema fingerprint and the replay limit")
struct ReevaluationRunnerExitTests {
    /// How long one runner invocation may take before the test fails and kills it.
    private static let runnerDeadline: DispatchTimeInterval = .seconds(60)
    /// How long each step after the deadline may take: SIGTERM, then SIGKILL, then the output read.
    private static let killGrace: DispatchTimeInterval = .seconds(5)

    // Every wait below is bounded, so a runner that never exits fails the test in about
    // runnerDeadline + 3 × killGrace. `.timeLimit` can't interrupt a blocked wait; it isn't used.
    @Test("--verify exits 10 for a record without a fingerprint and 13 for one of another schema")
    func exitsOnFingerprint() throws {
        let runner = try Self.builtRunner()
        let cases: [(fingerprint: String?, exit: Int32)] = [(nil, 10), ("0123456789abcdef", 13)]
        for (fingerprint, expected) in cases {
            let record = try Self.writeRecord(schemaFingerprint: fingerprint)
            defer { try? FileManager.default.removeItem(at: record) }
            let label = fingerprint ?? "no fingerprint"
            guard let result = try Self.run(runner, ["--input", record.path, "--verify"], label: label) else { continue }
            #expect(result.reason == .exit)
            #expect(result.status == expected, "\(label): \(result.text.suffix(400))")
            #expect(result.text.contains("schema fingerprint"))
        }
    }

    /// A record of six ticks (ids 0...5): its last tick + 1 is 6, so a limit of 5 refuses it and
    /// a limit of 6 takes it.
    private static let sixTickLimit = "5"
    private static let sixTickLimitJustEnough = "6"

    @Test("--convert refuses a record past --max-replay-ticks with exit 14 and writes nothing, JSON or 3.x")
    func convertRefusesALongRecord() throws {
        let runner = try Self.builtRunner()
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (format, input) in try Self.sixTickRecords(runner: runner, in: scratch) {
            let outputDirectory = scratch.appendingPathComponent("out-\(format)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let output = outputDirectory.appendingPathComponent("converted")

            if let refused = try Self.run(
                runner, ["--convert", input.path, output.path, "--max-replay-ticks", Self.sixTickLimit], label: "\(format) refused"
            ) {
                #expect(refused.reason == .exit)
                #expect(refused.status == 14, "\(format): \(refused.text.suffix(400))")
                #expect(refused.text.contains("--max-replay-ticks"), "\(format): \(refused.text.suffix(400))")
            }
            // Nothing is written: not the output, and not a spool file next to it.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
            #expect(leftovers.isEmpty, "\(format): the refused convert left \(leftovers)")

            // The same record converts when the limit takes it, so the refusal above is the limit's.
            if let accepted = try Self.run(
                runner, ["--convert", input.path, output.path, "--max-replay-ticks", Self.sixTickLimitJustEnough], label: "\(format) accepted"
            ) {
                #expect(accepted.reason == .exit)
                #expect(accepted.status == 0, "\(format): \(accepted.text.suffix(400))")
                #expect(FileManager.default.fileExists(atPath: output.path), "\(format): no output written")
            }
        }
    }

    @Test("--time-open refuses a record past --max-replay-ticks with exit 14 and prints no timing, JSON or 3.x")
    func timeOpenRefusesALongRecord() throws {
        let runner = try Self.builtRunner()
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (format, input) in try Self.sixTickRecords(runner: runner, in: scratch) {
            if let refused = try Self.run(
                runner, ["--time-open", input.path, "--repeat", "1", "--max-replay-ticks", Self.sixTickLimit], label: "\(format) refused"
            ) {
                #expect(refused.reason == .exit)
                #expect(refused.status == 14, "\(format): \(refused.text.suffix(400))")
                #expect(refused.text.contains("--max-replay-ticks"), "\(format): \(refused.text.suffix(400))")
                #expect(!refused.text.contains("maxTickIdSum"), "\(format): a timing line was printed")
            }
            if let accepted = try Self.run(
                runner, ["--time-open", input.path, "--repeat", "1", "--max-replay-ticks", Self.sixTickLimitJustEnough], label: "\(format) accepted"
            ) {
                #expect(accepted.reason == .exit)
                #expect(accepted.status == 0, "\(format): \(accepted.text.suffix(400))")
                #expect(accepted.text.contains("maxTickIdSum"), "\(format): no timing line: \(accepted.text.suffix(400))")
            }
        }
    }

    private struct RunnerResult {
        let reason: Process.TerminationReason
        let status: Int32
        let text: String
    }

    /// The built runner, or a failure that says to build it first.
    private static func builtRunner() throws -> URL {
        let products = try #require(
            productsDirectory(), "can't find this test bundle's build products directory in \(CommandLine.arguments)"
        )
        let runner = products.appendingPathComponent("ReevaluationRunner")
        try #require(
            FileManager.default.isExecutableFile(atPath: runner.path),
            "ReevaluationRunner isn't built in \(products.path): run `swift build` first"
        )
        return runner
    }

    /// Runs the runner with `arguments` and returns how it ended with its output. A runner that
    /// doesn't exit in time is killed and recorded as an issue, and the result is nil.
    private static func run(_ runner: URL, _ arguments: [String], label: String) throws -> RunnerResult? {
        let process = Process()
        process.executableURL = runner
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Read on another thread, started once the runner runs, so a runner that fills the
        // pipe can't block its own exit.
        let read = DispatchGroup()
        nonisolated(unsafe) var data = Data()
        read.enter()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }
        if exited.wait(timeout: .now() + runnerDeadline) == .timedOut {
            Issue.record("ReevaluationRunner didn't exit within \(runnerDeadline) (\(label)); killing it")
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                if exited.wait(timeout: .now() + killGrace) == .timedOut {
                    Issue.record("ReevaluationRunner didn't exit after SIGKILL (\(label))")
                    return nil
                }
            }
        }
        if read.wait(timeout: .now() + killGrace) == .timedOut {
            Issue.record("ReevaluationRunner's output stayed open after it exited (\(label))")
            return nil
        }
        return RunnerResult(
            reason: process.terminationReason,
            status: process.terminationStatus,
            text: String(decoding: data, as: UTF8.self)
        )
    }

    private static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runner-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The same six-tick record as a JSON file and as a 3.x file (the runner converts the JSON one
    /// with the default limit), in `scratch`.
    private static func sixTickRecords(runner: URL, in scratch: URL) throws -> [(format: String, url: URL)] {
        let json = try writeRecord(schemaFingerprint: nil, frames: 6, in: scratch)
        let threeXDirectory = scratch.appendingPathComponent("three-x")
        try FileManager.default.createDirectory(at: threeXDirectory, withIntermediateDirectories: true)
        let threeX = threeXDirectory.appendingPathComponent("record")
        let made = try run(runner, ["--convert", json.path, threeX.path], label: "make the 3.x record")
        try #require(made?.status == 0, "the runner can't write the 3.x record: \(made?.text.suffix(400) ?? "no result")")
        let written = try Data(contentsOf: threeX)
        try #require(ReevaluationRecordLog.hasMagic(written), "the converted record isn't a 3.x record")
        return [("JSON", json), ("3.x", threeX)]
    }

    /// The directory that holds this test bundle, which is where `swift build` put the package's
    /// executables for the same configuration and scratch path. The test process names the bundle
    /// in its arguments, in one of two layouts:
    /// - SwiftPM's native build system: on Linux the `<name>.xctest` executable is `argv[0]`; on
    ///   macOS the testing helper is passed `<name>.xctest/Contents/MacOS/<name>`. The directory is
    ///   the parent of the `.xctest` component.
    /// - The swift-build system (SwiftPM's default from Swift 6.4): each test target is an
    ///   executable `<target>-test-runner` beside the products, with no `.xctest` component. The
    ///   directory is the runner's own.
    /// Only the arguments: on Linux `Bundle.allBundles` crashed the test process (a null
    /// dereference in CFBundleGetAllBundles), and `dladdr` isn't visible from Swift's Glibc module.
    private static func productsDirectory() -> URL? {
        for argument in CommandLine.arguments {
            let url = URL(fileURLWithPath: argument).standardizedFileURL
            let components = url.pathComponents
            if let bundle = components.firstIndex(where: { $0.hasSuffix(".xctest") }) {
                return URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<bundle])))
            }
            if url.lastPathComponent.hasSuffix("-test-runner") {
                return url.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// A JSON record of hero-defense at the current version, one frame unless `frames` says more
    /// (tick ids 0..<frames), in the temporary directory unless `directory` says another.
    private static func writeRecord(schemaFingerprint: String?, frames: Int = 1, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("runner-exit-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecordFile(
            recordMetadata: ReevaluationRecordMetadata(
                landID: "hero-defense:runner-exit",
                landType: "hero-defense",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: [:],
                landDefinitionID: "hero-defense",
                version: ReevaluationRecordVersion.current,
                schemaFingerprint: schemaFingerprint
            ),
            tickFrames: (0 ..< Int64(frames)).map {
                ReevaluationTickFrame(tickId: $0, actions: [], clientEvents: [], lifecycleEvents: [])
            }
        )).write(to: url)
        return url
    }

    private struct RecordFile: Codable {
        let recordMetadata: ReevaluationRecordMetadata
        let tickFrames: [ReevaluationTickFrame]
    }
}
