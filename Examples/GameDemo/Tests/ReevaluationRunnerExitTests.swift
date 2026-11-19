// Tests/ReevaluationRunnerExitTests.swift
//
// `ReevaluationRunner --verify` refuses a record by its schema fingerprint before the first step
// (#521 D15): exit 10 for a record without one, 13 for one of another schema. Runs the runner
// from the same build products as this test bundle, and kills it if it doesn't exit in time.

import Foundation
import SwiftStateTree
import Testing

@Suite("ReevaluationRunner exit codes for the record schema fingerprint")
struct ReevaluationRunnerExitTests {
    /// How long one runner invocation may take before it is killed and the test fails.
    private static let runnerDeadline: DispatchTimeInterval = .seconds(60)

    @Test("--verify exits 10 for a record without a fingerprint and 13 for one of another schema", .timeLimit(.minutes(3)))
    func exitsOnFingerprint() throws {
        let products = try #require(Self.productsDirectory(), "can't find this test bundle's build products directory")
        let runner = products.appendingPathComponent("ReevaluationRunner")
        try #require(
            FileManager.default.isExecutableFile(atPath: runner.path),
            "ReevaluationRunner isn't built in \(products.path): run `swift build` first"
        )
        let cases: [(fingerprint: String?, exit: Int32)] = [(nil, 10), ("0123456789abcdef", 13)]
        for (fingerprint, expected) in cases {
            let record = try Self.writeRecord(schemaFingerprint: fingerprint)
            defer { try? FileManager.default.removeItem(at: record) }
            let process = Process()
            process.executableURL = runner
            process.arguments = ["--input", record.path, "--verify"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            // Read on another thread, so a runner that fills the pipe can't block its own exit.
            let read = DispatchGroup()
            nonisolated(unsafe) var data = Data()
            read.enter()
            DispatchQueue.global().async {
                data = output.fileHandleForReading.readDataToEndOfFile()
                read.leave()
            }
            try process.run()
            if exited.wait(timeout: .now() + Self.runnerDeadline) == .timedOut {
                process.terminate()
                exited.wait()
                Issue.record("ReevaluationRunner didn't exit within \(Self.runnerDeadline) (\(fingerprint ?? "no fingerprint")); killed it")
            }
            read.wait()
            let text = String(decoding: data, as: UTF8.self)
            #expect(process.terminationReason == .exit)
            #expect(process.terminationStatus == expected, "\(fingerprint ?? "no fingerprint"): \(text.suffix(400))")
            #expect(text.contains("schema fingerprint"))
        }
    }

    /// The directory that holds this test bundle, which is where `swift build` put the package's
    /// executables for the same configuration and scratch path. The test process names the bundle
    /// in its arguments: on Linux the `.xctest` executable is `argv[0]`; on macOS the testing
    /// helper is passed the bundle's executable inside `<name>.xctest/Contents/MacOS/`.
    private static func productsDirectory() -> URL? {
        let paths = CommandLine.arguments + Bundle.allBundles.map(\.bundlePath)
        for path in paths {
            guard let range = path.range(of: ".xctest") else { continue }
            let bundle = URL(fileURLWithPath: String(path[..<range.upperBound]))
            return bundle.deletingLastPathComponent()
        }
        return nil
    }

    /// A one-frame JSON record of hero-defense at the current version.
    private static func writeRecord(schemaFingerprint: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
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
            tickFrames: [ReevaluationTickFrame(tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [])]
        )).write(to: url)
        return url
    }

    private struct RecordFile: Codable {
        let recordMetadata: ReevaluationRecordMetadata
        let tickFrames: [ReevaluationTickFrame]
    }
}
