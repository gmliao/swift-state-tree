// Tests/SwiftStateTreeTests/ReevaluationRecordVersionTests.swift
//
// Record format versions are compared by major version only.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("Re-evaluation record version")
struct ReevaluationRecordVersionTests {
    @Test("The producer writes 2.1")
    func currentVersion() {
        #expect(ReevaluationRecordVersion.current == "2.1")
    }

    @Test("Same major, any minor, is compatible in both directions")
    func sameMajor() {
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.1", required: "2.0"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.0", required: "2.1"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.0", required: "2.0"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.7", required: "2"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2", required: "2.1"))
    }

    @Test("A different major, a missing or a malformed version is not")
    func incompatible() {
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "1.0", required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "3.0", required: "2.1"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: nil, required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "", required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "x.1", required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "2.0", required: "two"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "20.0", required: "2.0"))
    }

    @Test("Minor versions are parsed for feature checks")
    func minor() {
        #expect(ReevaluationRecordVersion.minor(of: "2.1") == 1)
        #expect(ReevaluationRecordVersion.minor(of: "2.0") == 0)
        #expect(ReevaluationRecordVersion.minor(of: "2") == 0)
        #expect(ReevaluationRecordVersion.minor(of: nil) == nil)
        #expect(ReevaluationRecordVersion.minor(of: "2.x") == nil)
    }

    @Test("ReevaluationEngine.run rejects a decodable record of another major version before replaying")
    func engineRejectsOtherMajor() async throws {
        for version in ["3.0", "1.0", "", "x"] as [String] {
            let url = try Self.writeEmptyRecord(version: version)
            defer { try? FileManager.default.removeItem(at: url) }
            // The record decodes: only the version gate rejects it.
            #expect(try await JSONReevaluationSource(filePath: url.path).getMetadata().version == version)
            await #expect(throws: ReevaluationRecordVersionError.incompatible(recorded: version, required: ReevaluationRecordVersion.current)) {
                _ = try await ReevaluationEngine.run(
                    definition: makeReevaluationEngineTestDefinition(),
                    initialState: ReevaluationEngineTestState(),
                    recordFilePath: url.path
                )
            }
        }
        let missing = try Self.writeEmptyRecord(version: nil)
        defer { try? FileManager.default.removeItem(at: missing) }
        await #expect(throws: ReevaluationRecordVersionError.incompatible(recorded: nil, required: ReevaluationRecordVersion.current)) {
            _ = try await ReevaluationEngine.run(
                definition: makeReevaluationEngineTestDefinition(),
                initialState: ReevaluationEngineTestState(),
                recordFilePath: missing.path
            )
        }
    }

    @Test("ReevaluationEngine.run accepts a 2.0 record")
    func engineAcceptsSameMajor() async throws {
        let url = try Self.writeEmptyRecord(version: "2.0")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ReevaluationEngine.run(
            definition: makeReevaluationEngineTestDefinition(),
            initialState: ReevaluationEngineTestState(),
            recordFilePath: url.path
        )
        #expect(result.syncStreamPresence == .absent(reason: "record version 2.0 predates sync-output recording"))
    }

    private static func writeEmptyRecord(version: String?) throws -> URL {
        struct File: Codable {
            let recordMetadata: ReevaluationRecordMetadata
            let tickFrames: [ReevaluationTickFrame]
        }
        let file = File(
            recordMetadata: ReevaluationRecordMetadata(
                landID: "reeval-engine-test:version",
                landType: "reeval-engine-test",
                createdAt: Date(timeIntervalSince1970: 0),
                metadata: [:],
                version: version
            ),
            tickFrames: [ReevaluationTickFrame(tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [])]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-version-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url)
        return url
    }
}
