// Tests/SwiftStateTreeTests/ReevaluationRecordVersionTests.swift
//
// Record format versions: the same major, from `minimumSupported` (2.5, #154) on.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("Re-evaluation record version")
struct ReevaluationRecordVersionTests {
    @Test("The producer writes 2.6 and reads 2.5 and later")
    func currentVersion() {
        #expect(ReevaluationRecordVersion.current == "2.6")
        #expect(ReevaluationRecordVersion.minimumSupported == "2.5")
    }

    @Test("Only an affected land's record older than 2.3 has a not-comparable hash (#175)")
    func hashIncomparability() {
        for old in ["2", "2.0", "2.1", "2.2"] {
            let reason = ReevaluationRecordVersion.hashIncomparability(recorded: old, stateType: HashPinState.self)
            #expect(reason?.contains("recorded before #175") == true, "\(old): \(reason ?? "nil")")
            #expect(reason?.contains("hash not comparable") == true)
            // Any other land's older record must still reproduce its hashes.
            #expect(ReevaluationRecordVersion.hashIncomparability(recorded: old, stateType: UnaffectedHashState.self) == nil)
        }
        for current in ["2.3", "2.4", ReevaluationRecordVersion.current] {
            #expect(ReevaluationRecordVersion.hashIncomparability(recorded: current, stateType: HashPinState.self) == nil)
        }
    }

    @Test("The #175 shape is found from the state type, at any depth")
    func changedShape() {
        let changed = ReevaluationRecordVersion.hashChangedByNestedNodePolicies
        #expect(changed(HashPinState.self), "[String: convertible node]")
        #expect(changed(PlayerKeyedHashState.self), "[PlayerID: convertible node]")
        #expect(changed(NestedHashState.self), "inside a node in an array in an optional")
        #expect(!changed(UnaffectedHashState.self), "Int keys, plain nodes, convertible values that are not nodes")
        #expect(!changed(PerPlayerHashState.self), "a per-player field is not in the broadcast view")
    }

    @Test("An older record's differing initialize hash is not comparable; a 2.3 record's fails")
    func initializeHashMismatch() {
        let state = HashPinState()
        let record = ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: "0000000000000000")
        let old = ReevaluationEngine.verifyInitialize(
            record: record, emitted: [], state: state, hashDefinition: .broadcastView,
            hashIncomparability: ReevaluationRecordVersion.hashIncomparability(recorded: "2.2", stateType: HashPinState.self)
        )
        guard case .notComparable(let reason) = old else {
            Issue.record("expected notComparable, got \(old)")
            return
        }
        #expect(reason.contains("recorded before #175"))
        let current = ReevaluationEngine.verifyInitialize(
            record: record, emitted: [], state: state,
            hashIncomparability: ReevaluationRecordVersion.hashIncomparability(recorded: ReevaluationRecordVersion.current, stateType: HashPinState.self)
        )
        guard case .failed = current else {
            Issue.record("expected failed, got \(current)")
            return
        }
        // A matching hash verifies whatever the version: older records of other lands still do.
        let matching = ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: ReevaluationEngine.calculateBroadcastViewHash(state))
        #expect(ReevaluationEngine.verifyInitialize(
            record: matching, emitted: [], state: state, hashDefinition: .broadcastView,
            hashIncomparability: ReevaluationRecordVersion.hashIncomparability(recorded: "2.2", stateType: HashPinState.self)
        ) == .passed)
        // An unaffected land's older record that differs is a real failure.
        let unaffected = ReevaluationEngine.verifyInitialize(
            record: record, emitted: [], state: UnaffectedHashState(), hashDefinition: .broadcastView,
            hashIncomparability: ReevaluationRecordVersion.hashIncomparability(recorded: "2.2", stateType: UnaffectedHashState.self)
        )
        guard case .failed = unaffected else {
            Issue.record("expected failed, got \(unaffected)")
            return
        }
    }

    @Test("The broadcast-view hash (records before 2.4) of a node in a String map leaves out its server-only fields (#175)")
    func pinnedHash() {
        var state = HashPinState()
        state.nodes["a"] = HashPinNode(shown: 1, secret: 2)
        let hash = ReevaluationEngine.calculateBroadcastViewHash(state)
        #expect(hash == "abbe170f091e4dd9")
        state.nodes["a"]?.secret = 99
        #expect(ReevaluationEngine.calculateBroadcastViewHash(state) == hash)
        #expect(ReevaluationEngine.calculateStateHash(state) != ReevaluationEngine.calculateStateHash(HashPinState()))
    }

    @Test("Same major from 2.5 on is compatible, whatever minor the reader requires")
    func sameMajor() {
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.5", required: "2.5"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.7", required: "2.5"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.5", required: "2.7"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.7", required: "2"))
        #expect(ReevaluationRecordVersion.unsupportedReason(recorded: "2.5") == nil)
        #expect(ReevaluationRecordVersion.unsupportedReason(recorded: "2.9") == nil)
    }

    @Test("A record older than 2.5 is unsupported, with a re-record reason (#154)")
    func olderThanMinimum() {
        for old in ["2", "2.0", "2.1", "2.3", "2.4"] {
            #expect(!ReevaluationRecordVersion.isCompatible(recorded: old, required: ReevaluationRecordVersion.current), "\(old)")
            let reason = ReevaluationRecordVersion.unsupportedReason(recorded: old)
            #expect(reason?.contains("unsupported record version \(old)") == true, "\(reason ?? "nil")")
            #expect(reason?.contains("re-record") == true)
        }
        // Another major, a missing or a malformed version is incompatible, not unsupported.
        for other in ["1.0", "3.0", "", "x", nil] as [String?] {
            #expect(ReevaluationRecordVersion.unsupportedReason(recorded: other) == nil, "\(other ?? "nil")")
        }
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

    @Test("ReevaluationEngine.run rejects a 2.4 record as unsupported before replaying (#154)")
    func engineRejectsOlderMinor() async throws {
        for version in ["2.4", "2.0"] {
            let url = try Self.writeEmptyRecord(version: version)
            defer { try? FileManager.default.removeItem(at: url) }
            let expected = ReevaluationRecordVersionError.unsupported(recorded: version, minimum: "2.5")
            await #expect(throws: expected) {
                _ = try await ReevaluationEngine.run(
                    definition: makeReevaluationEngineTestDefinition(),
                    initialState: ReevaluationEngineTestState(),
                    recordFilePath: url.path
                )
            }
            #expect(expected.description.contains("re-record"))
        }
    }

    @Test("ReevaluationEngine.run accepts a 2.5 record")
    func engineAcceptsSameMajor() async throws {
        let url = try Self.writeEmptyRecord(version: "2.5")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ReevaluationEngine.run(
            definition: makeReevaluationEngineTestDefinition(),
            initialState: ReevaluationEngineTestState(),
            recordFilePath: url.path
        )
        #expect(result.hashDefinition == .fullState)
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

@StateNodeBuilder
struct PlainHashNode: StateNodeProtocol {
    @Sync(.serverOnly) var secret: Int = 0

    init() {}
}

@SnapshotConvertible
struct ConvertibleHashValue: StateProtocol {
    var value: Int = 0

    init() {}
}

@StateNodeBuilder
struct PlayerKeyedHashState: StateNodeProtocol {
    @Sync(.broadcast) var players: [PlayerID: HashPinNode] = [:]

    init() {}
}

@StateNodeBuilder
struct ArrayHolderNode: StateNodeProtocol {
    @Sync(.broadcast) var inner: [String: HashPinNode] = [:]

    init() {}
}

@StateNodeBuilder
struct NestedHashState: StateNodeProtocol {
    @Sync(.broadcast) var holders: [ArrayHolderNode]? = nil

    init() {}
}

@StateNodeBuilder
struct UnaffectedHashState: StateNodeProtocol {
    @Sync(.broadcast) var byInt: [Int: HashPinNode] = [:]
    @Sync(.broadcast) var plain: [String: PlainHashNode] = [:]
    @Sync(.broadcast) var values: [String: ConvertibleHashValue] = [:]
    @Sync(.broadcast) var single: HashPinNode = HashPinNode()

    init() {}
}

@StateNodeBuilder
struct PerPlayerHashState: StateNodeProtocol {
    @Sync(.perPlayer({ (value: [String: HashPinNode], _: PlayerID) in value }))
    var nodes: [String: HashPinNode] = [:]

    init() {}
}

@Test("The recorder stamps the version this build writes, whatever the caller passes")
func recorderStampsCurrentVersion() async throws {
    let recorder = ReevaluationRecorder()
    for passed in [nil, "1.0", "2.0", "2.3", "9.9"] as [String?] {
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: "stamp:local", landType: "stamp", createdAt: Date(timeIntervalSince1970: 0),
            metadata: [:], version: passed
        ))
        #expect(await recorder.getMetadata()?.version == ReevaluationRecordVersion.current, "\(String(describing: passed))")
    }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await recorder.save(to: path)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
    #expect((saved?["recordMetadata"] as? [String: Any])?["version"] as? String == ReevaluationRecordVersion.current)
}
