// Tests/ReevaluationRunnerExitTests.swift
//
// `ReevaluationRunner --verify` refuses a record by its schema fingerprint before the first step
// (#521 D15): exit 10 for a record without one, 13 for one of another schema. Runs the runner
// `swift test` built.

import Foundation
import SwiftStateTree
import Testing

@Suite("ReevaluationRunner exit codes for the record schema fingerprint")
struct ReevaluationRunnerExitTests {
    @Test("--verify exits 10 for a record without a fingerprint and 13 for one of another schema")
    func exitsOnFingerprint() throws {
        let runner = try #require(Self.runnerURL(), "ReevaluationRunner isn't built: run `swift build` first")
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
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationReason == .exit)
            #expect(process.terminationStatus == expected, "\(fingerprint ?? "no fingerprint"): \(text.suffix(400))")
            #expect(text.contains("schema fingerprint"))
        }
    }

    /// The runner beside the build products of this package: `.build/<configuration>`, newest first.
    private static func runnerURL() -> URL? {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["debug", "release"].map {
            packageRoot.appendingPathComponent(".build/\($0)/ReevaluationRunner")
        }
        let existing = candidates.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        return existing.max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
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
