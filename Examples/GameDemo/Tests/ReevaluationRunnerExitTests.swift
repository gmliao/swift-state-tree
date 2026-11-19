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
    /// How long one runner invocation may take before the test fails and kills it.
    private static let runnerDeadline: DispatchTimeInterval = .seconds(60)
    /// How long each step after the deadline may take: SIGTERM, then SIGKILL, then the output read.
    private static let killGrace: DispatchTimeInterval = .seconds(5)

    // Every wait below is bounded, so a runner that never exits fails the test in about
    // runnerDeadline + 3 × killGrace. `.timeLimit` can't interrupt a blocked wait; it isn't used.
    @Test("--verify exits 10 for a record without a fingerprint and 13 for one of another schema")
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
            let label = fingerprint ?? "no fingerprint"
            if exited.wait(timeout: .now() + Self.runnerDeadline) == .timedOut {
                Issue.record("ReevaluationRunner didn't exit within \(Self.runnerDeadline) (\(label)); killing it")
                process.terminate()
                if exited.wait(timeout: .now() + Self.killGrace) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    if exited.wait(timeout: .now() + Self.killGrace) == .timedOut {
                        Issue.record("ReevaluationRunner didn't exit after SIGKILL (\(label))")
                        continue
                    }
                }
            }
            if read.wait(timeout: .now() + Self.killGrace) == .timedOut {
                Issue.record("ReevaluationRunner's output stayed open after it exited (\(label))")
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            #expect(process.terminationReason == .exit)
            #expect(process.terminationStatus == expected, "\(fingerprint ?? "no fingerprint"): \(text.suffix(400))")
            #expect(text.contains("schema fingerprint"))
        }
    }

    /// The directory that holds this test bundle, which is where `swift build` put the package's
    /// executables for the same configuration and scratch path. The test process names the bundle
    /// in its arguments: on Linux the `<name>.xctest` executable is `argv[0]`; on macOS the testing
    /// helper is passed `<name>.xctest/Contents/MacOS/<name>`. Only the arguments: on Linux
    /// `Bundle.allBundles` crashed the test process (a null dereference in CFBundleGetAllBundles),
    /// and `dladdr` isn't visible from Swift's Glibc module.
    private static func productsDirectory() -> URL? {
        for argument in CommandLine.arguments {
            let components = URL(fileURLWithPath: argument).standardizedFileURL.pathComponents
            guard let bundle = components.firstIndex(where: { $0.hasSuffix(".xctest") }) else { continue }
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<bundle])))
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
