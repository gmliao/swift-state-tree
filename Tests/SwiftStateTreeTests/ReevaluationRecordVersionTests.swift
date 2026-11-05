// Tests/SwiftStateTreeTests/ReevaluationRecordVersionTests.swift
//
// Record format versions are compared by major version only.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("Re-evaluation record version")
struct ReevaluationRecordVersionTests {
    @Test("The producer writes 2.3")
    func currentVersion() {
        #expect(ReevaluationRecordVersion.current == "2.3")
    }

    @Test("Hashes of a record older than 2.3 are reported as not comparable (#175)")
    func hashIncomparability() {
        for old in ["2", "2.0", "2.1", "2.2"] {
            let reason = ReevaluationRecordVersion.hashIncomparability(recorded: old)
            #expect(reason?.contains("recorded before #175") == true, "\(old): \(reason ?? "nil")")
            #expect(reason?.contains("hash not comparable") == true)
        }
        #expect(ReevaluationRecordVersion.hashIncomparability(recorded: "2.3") == nil)
        #expect(ReevaluationRecordVersion.hashIncomparability(recorded: "2.4") == nil)
        #expect(ReevaluationRecordVersion.hashIncomparability(recorded: ReevaluationRecordVersion.current) == nil)
    }

    @Test("An older record's differing initialize hash is not comparable; a 2.3 record's fails")
    func initializeHashMismatch() {
        let state = HashPinState()
        let record = ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: "0000000000000000")
        let old = ReevaluationEngine.verifyInitialize(
            record: record, emitted: [], state: state,
            hashIncomparability: ReevaluationRecordVersion.hashIncomparability(recorded: "2.2")
        )
        guard case .notComparable(let reason) = old else {
            Issue.record("expected notComparable, got \(old)")
            return
        }
        #expect(reason.contains("recorded before #175"))
        let current = ReevaluationEngine.verifyInitialize(
            record: record, emitted: [], state: state,
            hashIncomparability: ReevaluationRecordVersion.hashIncomparability(recorded: ReevaluationRecordVersion.current)
        )
        guard case .failed = current else {
            Issue.record("expected failed, got \(current)")
            return
        }
        // A matching hash verifies whatever the version: older records of other lands still do.
        let matching = ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: ReevaluationEngine.calculateStateHash(state))
        #expect(ReevaluationEngine.verifyInitialize(
            record: matching, emitted: [], state: state,
            hashIncomparability: ReevaluationRecordVersion.hashIncomparability(recorded: "2.2")
        ) == .passed)
    }

    @Test("The state hash of a state node in a String map leaves out its server-only fields (#175)")
    func pinnedHash() {
        var state = HashPinState()
        state.nodes["a"] = HashPinNode(shown: 1, secret: 2)
        let hash = ReevaluationEngine.calculateStateHash(state)
        #expect(hash == "abbe170f091e4dd9")
        state.nodes["a"]?.secret = 99
        #expect(ReevaluationEngine.calculateStateHash(state) == hash)
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

@StateNodeBuilder
@SnapshotConvertible
struct HashPinNode: StateNodeProtocol {
    @Sync(.broadcast) var shown: Int = 0
    @Sync(.serverOnly) var secret: Int = 0

    init() {}

    init(shown: Int, secret: Int) {
        self.shown = shown
        self.secret = secret
    }
}

@StateNodeBuilder
struct HashPinState: StateNodeProtocol {
    @Sync(.broadcast) var nodes: [String: HashPinNode] = [:]

    init() {}
}
