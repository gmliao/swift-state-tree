// Tests/SwiftStateTreeNIOTests/Differential/DiffGolden.swift
//
// The golden captures (#555, plan rev 10 "Golden captures"): one file per scenario and cell,
// with each frame's and the record's bytes beside their decoded views, and an index listing
// every expected file. The folder is found from this file's path, with no resources entry.
//
// Keys (the named constants below):
// - `SST_UPDATE_GOLDEN=1`: the run writes candidates into `SST_GOLDEN_OUT` instead of
//   comparing. Only the recorder script sets it; it runs five processes and publishes.
// - `SST_DIFFERENTIAL_VERIFY=1`: the gate jobs; an update fails at start.
// - `SST_TOOLCHAIN`: the platform and `swift --version` line the script and the gate jobs
//   set. Bytes are compared only when it equals the golden's; otherwise decoded views only.
// - `SST_GOLDEN_COMMIT`: the commit the script records at.

#if DEBUG
import Foundation
@testable import SwiftStateTree

enum DiffGoldenKeys {
    static let update = "SST_UPDATE_GOLDEN"
    static let output = "SST_GOLDEN_OUT"
    static let verify = "SST_DIFFERENTIAL_VERIFY"
    static let toolchain = "SST_TOOLCHAIN"
    static let commit = "SST_GOLDEN_COMMIT"
}

/// What a golden was recorded with.
struct DiffRecordedWith: Codable, Equatable, Sendable {
    let commit: String
    let toolchain: String
}

/// One golden file.
struct DiffGoldenFile: Codable, Equatable, Sendable {
    let scenario: String
    let cell: String
    let recordedWith: DiffRecordedWith
    let result: DiffRunResult
}

/// The index: every scenario and cell that must have a file.
struct DiffGoldenIndex: Codable, Equatable, Sendable {
    let files: [String]
}

enum DiffGolden {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
    static let indexName = "index.json"

    static func fileName(_ scenario: DiffScenario, _ cell: DiffCell) -> String {
        "\(scenario.name).\(cell).json"
    }

    /// Every file the scenarios claim, sorted.
    static func expectedFiles(_ scenarios: [DiffScenario]) -> [String] {
        scenarios.flatMap { scenario in scenario.cells.cells.map { fileName(scenario, $0) } }.sorted()
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var isUpdating: Bool { environment[DiffGoldenKeys.update] == "1" }
    static var isVerifying: Bool { environment[DiffGoldenKeys.verify] == "1" }
    static var toolchain: String { environment[DiffGoldenKeys.toolchain] ?? "unknown" }

    /// Why an update must not run in `environment`, or nil: the gate jobs set the verify key, and
    /// an update there would rewrite what they compare.
    static func updateRefusal(environment: [String: String]) -> String? {
        guard environment[DiffGoldenKeys.update] == "1", environment[DiffGoldenKeys.verify] == "1" else { return nil }
        return "\(DiffGoldenKeys.update)=1 is refused under \(DiffGoldenKeys.verify)=1"
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// The candidate folder of an update run.
    static func outputFolder() throws -> URL {
        guard let path = environment[DiffGoldenKeys.output], !path.isEmpty else {
            throw DiffRunFailure("\(DiffGoldenKeys.update)=1 needs \(DiffGoldenKeys.output), the candidate folder")
        }
        return URL(fileURLWithPath: path)
    }

    static func write(_ file: DiffGoldenFile, named name: String, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder().encode(file).write(to: folder.appendingPathComponent(name))
    }

    static func writeIndex(_ scenarios: [DiffScenario], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder().encode(DiffGoldenIndex(files: expectedFiles(scenarios))).write(to: folder.appendingPathComponent(indexName))
    }

    static func read(named name: String, in folder: URL = folder) throws -> DiffGoldenFile {
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiffRunFailure("no golden \(name): record it with the recorder script")
        }
        return try JSONDecoder().decode(DiffGoldenFile.self, from: Data(contentsOf: url))
    }

    static func readIndex(in folder: URL = folder) throws -> DiffGoldenIndex {
        let url = folder.appendingPathComponent(indexName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DiffRunFailure("no golden index") }
        return try JSONDecoder().decode(DiffGoldenIndex.self, from: Data(contentsOf: url))
    }

    /// The golden files present in `folder`, the index excluded.
    static func presentFiles(in folder: URL = folder) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0 != indexName }.sorted()
    }

    /// Each stored decoded view equals the one derived from its bytes. A file that fails is
    /// corrupt: its readable diff can't be trusted.
    static func corruption(of result: DiffRunResult) -> String? {
        for (checkpoint, capture) in [("live", result.live), ("terminal", result.terminal)] {
            for (name, connection) in capture.connections.sorted(by: { $0.key < $1.key }) {
                for (index, frame) in connection.frames.enumerated() {
                    guard let derived = try? DiffValue.decodeFrame(frame.bytes) else {
                        return "\(checkpoint) \(name) frame \(index): its bytes don't decode"
                    }
                    if derived != frame.decoded { return "\(checkpoint) \(name) frame \(index): the decoded view isn't its bytes'" }
                }
            }
        }
        guard let contents = try? ReevaluationRecordLog.decodeForTesting(Array(result.record.bytes)),
              let derived = try? DiffRun.decodedView(contents) else {
            return "the record's bytes don't decode"
        }
        if derived != result.record.decoded { return "the record's decoded view isn't its bytes'" }
        if (contents.completeness == .complete) != result.record.complete { return "the record's completeness isn't its bytes'" }
        return nil
    }
}
#endif
