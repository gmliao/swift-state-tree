// Tests/SwiftStateTreeTransportTests/RecordFieldListTests.swift
//
// The replay record's field list (#555): every field of the record's types is named with its
// comparison rule, so a field added later fails here until it is classified. The fields are read
// from the types by a probing decoder, not from a recorded value, so a field that no fixture fills
// (a nil optional, an empty collection, another case) is checked too.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct RecordFieldsState: StateNodeProtocol {
    @Sync(.broadcast)
    var values: [Int] = []
}

/// Values for the record's enums whose raw values the probe can't guess, and for a leaf that
/// validates what it decodes.
private nonisolated(unsafe) let recordSamples: [any Decodable] = [
    ReevaluationRecordedSyncOutput.TurnKind.tick,
    SyncHashCoding(0),
    ReevaluationRecordedSyncMarker.Kind.seed,
    ReevaluationRecordedSyncMarker.ViewDrop.extraction,
    LandFailure.Kind.syncPlan,
    LandFailurePosition.Stage.input,
]

/// The record's types that pick their fields by a string discriminator, with every value.
private let recordCases: [ObjectIdentifier: [String]] = [
    ObjectIdentifier(StatePatch.self): ["replace", "add", "remove"],
]

private func probeRecordTypes() -> RecordFieldProbeResult {
    let metadata = RecordFieldProbe.probe(ReevaluationRecordMetadata.self, at: "metadata", samples: recordSamples, cases: recordCases)
    let frames = RecordFieldProbe.probe(ReevaluationTickFrame.self, at: "frames[]", samples: recordSamples, cases: recordCases)
    return RecordFieldProbeResult(paths: metadata.paths.union(frames.paths), opaque: metadata.opaque.union(frames.opaque))
}

@Suite("Replay record field list (#555)")
struct RecordFieldListTests {
    @Test("Every field of the record's types is on the field list")
    func everyFieldIsClassified() async throws {
        let probe = probeRecordTypes()
        #expect(probe.opaque.isEmpty, "give each opaque type a sample or its cases: \(probe.opaque.sorted())")
        // Fields only some records fill: optional, in-turn only, a discriminated case.
        #expect(probe.paths.isSuperset(of: [
            "metadata.rngSeed", "metadata.hardwareInfo.cpuModel", "frames[].landFailure.kind",
            "frames[].syncMarkers[].viewHash", "frames[].syncOutputs[].patches[][].value",
        ]))
        #expect(RecordFieldList.unclassified(probe.paths) == [], "classify each new field in RecordFieldList")

        // The decoded contents' own fields, from a saved record.
        let contents = try await savedRecordContents()
        #expect(contents.completeness == .complete)
        let ownFields = Set(Mirror(reflecting: contents).children.compactMap(\.label))
        #expect(ownFields == ["metadata", "frames", "completeness", "holdsNonNFCText"])
        #expect(RecordFieldList.unclassified(ownFields) == [])
    }

    @Test("A field on neither list is unclassified; a pinned field covers its subtree")
    func unclassifiedFieldFails() {
        #expect(RecordFieldList.unclassified(["metadata.landID", "metadata.newField", "frames[].actions[].newField"])
            == ["frames[].actions[].newField", "metadata.newField"])
        #expect(RecordFieldList.rule(for: "metadata.hardwareInfo.cpuModel") == .pinned(because: "the recording machine"))
        #expect(RecordFieldList.rule(for: "metadata.createdAtLocal") == nil, "a prefix match is by whole field")
        #expect(RecordFieldList.rule(for: "frames[].actions[].clientID") == .compared)
    }

    @Test("The probe names nil optionals, empty collections, dictionary values and every case")
    func probeNamesUnfilledFields() {
        struct Inner: Decodable { let x: Int; let tags: [String] }
        struct Outer: Decodable { let a: Inner; let b: Inner?; let c: [Inner]; let d: [String: Inner] }
        #expect(RecordFieldProbe.probe(Outer.self) == RecordFieldProbeResult(paths: [
            "a", "a.x", "a.tags", "b", "b.x", "b.tags", "c", "c[].x", "c[].tags", "d", "d[].x", "d[].tags",
        ]))

        // A type that reads `extra` only in one case: probed once per case, so `extra` is named.
        struct Tagged: Decodable {
            enum CodingKeys: String, CodingKey { case kind, extra }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if try container.decode(String.self, forKey: .kind) == "rich" {
                    _ = try container.decode(Int.self, forKey: .extra)
                }
            }
        }
        #expect(RecordFieldProbe.probe(Tagged.self).paths == ["kind"])
        #expect(RecordFieldProbe.probe(Tagged.self, cases: [ObjectIdentifier(Tagged.self): ["plain", "rich"]]).paths == ["kind", "extra"])

        // An enum whose raw value the probe can't guess is reported, not skipped.
        enum Mode: String, Decodable { case on }
        struct WithMode: Decodable { let mode: Mode; let after: Int }
        #expect(RecordFieldProbe.probe(WithMode.self).opaque == ["mode"])
        #expect(RecordFieldProbe.probe(WithMode.self, samples: [Mode.on]) == RecordFieldProbeResult(paths: ["mode", "after"]))
    }
}

/// A record saved by a keeper with no transport: enough for the contents' own fields.
private func savedRecordContents() async throws -> ReevaluationRecordLogContents {
    let landID = "record-fields:local"
    let definition = Land("record-fields", using: RecordFieldsState.self) { Rules {} }
    let keeper = LandKeeper<RecordFieldsState>(
        definition: definition,
        initialState: RecordFieldsState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    await keeper.setLandID(landID)
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID,
        landType: "record-fields",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "record-fields",
        rngSeed: DeterministicSeed.fromLandID(landID),
        recordsSyncStream: await keeper.recordsSyncStream,
        syncConfig: nil
    ))
    await keeper.waitForRecorderSubmissionsForTesting()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-fields-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("record.sstr").path
    try await recorder.save(to: path)
    return try ReevaluationRecordLog.decodeForTesting(Array(try Data(contentsOf: URL(fileURLWithPath: path))))
}
