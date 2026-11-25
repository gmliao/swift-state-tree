// Tests/SwiftStateTreeTransportTests/RecordFieldListTests.swift
//
// The replay record's field list (#555): every field of the record's types is named with its
// comparison rule, so a field added later fails here until it is classified. The fields are read
// from the types by a probing decoder, not from a recorded value, so a field that no fixture fills
// (a nil optional, an empty collection, another case) is checked too.
//
// The root is the decoded contents (`ReevaluationRecordLogContents`: metadata, frames,
// completeness), not the wire records (`ReevaluationLogRecord`, a header, turns and a footer).
// The golden stores the record's bytes, compared byte for byte in the pinned image, and its decoded
// view, which is these contents; the wire framing is covered by the bytes, and the field list
// classifies what the decoded view compares.

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
/// validates what it decodes: two of each, one per run, so a type that branches on one is found.
private nonisolated(unsafe) let recordSamples: [any Decodable] = [
    ReevaluationRecordedSyncOutput.TurnKind.tick, ReevaluationRecordedSyncOutput.TurnKind.legacyCycle,
    SyncHashCoding(0), SyncHashCoding(1),
    ReevaluationRecordedSyncMarker.Kind.seed, ReevaluationRecordedSyncMarker.Kind.initialize,
    ReevaluationRecordedSyncMarker.ViewDrop.extraction, ReevaluationRecordedSyncMarker.ViewDrop.encode,
    LandFailure.Kind.syncPlan, LandFailure.Kind.handlerWrite,
    LandFailurePosition.Stage.input, LandFailurePosition.Stage.actionResponse,
    RecordPayloadEncoding.json, RecordPayloadEncoding.messagepack,
]

/// Dynamic values: their content is a payload or a state value, not a fixed field set, so the
/// probe returns these unprobed and reports where they sit (`recordBoundaryPaths`). The decoded
/// view compares them as values.
private nonisolated(unsafe) let recordBoundaries: [any Decodable] = [
    AnyCodable(Int(0)),
    SnapshotValue.null,
]

/// Where the record holds dynamic values: payloads, resolver outputs, patch values and the
/// metadata's free-form maps. An action's and a client event's payload are bytes from 3.7
/// (#700 K1a), a leaf.
private let recordBoundaryPaths: Set<String> = [
    "frames[].actions[].resolverOutputs[].value",
    "frames[].initialize.serverEvents[].payload",
    "frames[].lifecycleEvents[].resolverOutputs[].value", "frames[].serverEvents[].payload",
    "frames[].syncOutputs[].patches[][].value",
    "metadata.extensions[]", "metadata.landConfig[]", "metadata.ruleParams[]",
]

/// The record's types that pick their fields by a string discriminator, with every value.
private let recordCases: [ObjectIdentifier: ProbeCases] = [
    ObjectIdentifier(StatePatch.self): ProbeCases(key: "op", values: ["replace", "add", "remove"]),
]

private func probeRecordTypes() -> RecordFieldProbeResult {
    let metadata = RecordFieldProbe.probe(
        ReevaluationRecordMetadata.self, at: "metadata", samples: recordSamples, boundaries: recordBoundaries, cases: recordCases
    )
    let frames = RecordFieldProbe.probe(
        ReevaluationTickFrame.self, at: "frames[]", samples: recordSamples, boundaries: recordBoundaries, cases: recordCases
    )
    return RecordFieldProbeResult(
        paths: metadata.paths.union(frames.paths),
        opaque: metadata.opaque.union(frames.opaque),
        recursive: metadata.recursive.union(frames.recursive),
        branching: metadata.branching.union(frames.branching),
        boundaries: metadata.boundaries.union(frames.boundaries),
        nonLeafSamples: metadata.nonLeafSamples.union(frames.nonLeafSamples)
    )
}

@Suite("Replay record field list (#555)")
struct RecordFieldListTests {
    @Test("Every field of the record's types is on the field list")
    func everyFieldIsClassified() async throws {
        let probe = probeRecordTypes()
        #expect(probe.opaque.isEmpty, "give each opaque type a sample or its cases: \(probe.opaque.sorted())")
        #expect(probe.recursive.isEmpty, "a recursive record type: \(probe.recursive.sorted())")
        #expect(probe.branching.isEmpty, "list the discriminator values in recordCases: \(probe.branching.sorted())")
        #expect(probe.nonLeafSamples.isEmpty, "a sample hides fields: \(probe.nonLeafSamples.sorted())")
        #expect(probe.boundaries == recordBoundaryPaths, "a new dynamic value: declare it in recordBoundaryPaths")
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

    @Test("The probe names nil optionals, empty collections, dictionary values and each listed case")
    func probeNamesUnfilledFields() {
        struct Inner: Decodable { let x: Int; let tags: [String] }
        struct Outer: Decodable { let a: Inner; let b: Inner?; let c: [Inner]; let d: [String: Inner] }
        #expect(RecordFieldProbe.probe(Outer.self) == RecordFieldProbeResult(paths: [
            "a", "a.x", "a.tags", "b", "b.x", "b.tags", "c", "c[].x", "c[].tags", "d", "d[].x", "d[].tags",
        ]))

        // A type that reads `extra` only in one case and rejects an unknown discriminator, as
        // `StatePatch` does. Without its cases neither run's string answer is a case, so it is
        // reported as opaque; with them, each case is probed and `extra` is named.
        struct Tagged: Decodable {
            enum CodingKeys: String, CodingKey { case kind, extra }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .kind) {
                case "plain": break
                case "rich": _ = try container.decode(Int.self, forKey: .extra)
                default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind")
                }
            }
        }
        #expect(RecordFieldProbe.probe(Tagged.self).opaque == [""])
        let taggedCases = ProbeCases(key: "kind", values: ["plain", "rich"])
        let tagged = RecordFieldProbe.probe(Tagged.self, cases: [ObjectIdentifier(Tagged.self): taggedCases])
        #expect(tagged.paths == ["kind", "extra"] && tagged.opaque.isEmpty && tagged.branching.isEmpty)

        // Listing the discriminator fixes only its key: a Boolean gate beside it still differs
        // between the runs and is reported.
        struct TaggedWithGate: Decodable {
            enum CodingKeys: String, CodingKey { case kind, compact, extra, wide }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .kind) {
                case "plain": break
                case "rich": _ = try container.decode(Int.self, forKey: .extra)
                default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind")
                }
                if try !container.decode(Bool.self, forKey: .compact) {
                    _ = try container.decode(Int.self, forKey: .wide)
                }
            }
        }
        let gatedCases = [ObjectIdentifier(TaggedWithGate.self): taggedCases]
        #expect(RecordFieldProbe.probe(TaggedWithGate.self, cases: gatedCases).branching == [""])

        // A gate that moves a field from one case to the other: the union over the cases is the
        // same in both runs, so the runs are compared case by case.
        struct GateMovesExtra: Decodable {
            enum CodingKeys: String, CodingKey { case kind, swap, extra }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let swap = try container.decode(Bool.self, forKey: .swap)
                switch try container.decode(String.self, forKey: .kind) {
                case "plain": if swap { _ = try container.decode(Int.self, forKey: .extra) }
                case "rich": if !swap { _ = try container.decode(Int.self, forKey: .extra) }
                default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind")
                }
            }
        }
        let moving = RecordFieldProbe.probe(GateMovesExtra.self, cases: [ObjectIdentifier(GateMovesExtra.self): taggedCases])
        #expect(moving.paths == ["kind", "swap", "extra"], "the union is the same in both runs")
        #expect(moving.branching == [""])

        // A gate on an enum is found too: the second run takes the last case.
        enum Layout: String, Decodable, CaseIterable { case narrow, wide }
        struct LayoutGated: Decodable {
            enum CodingKeys: String, CodingKey { case layout, columns }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if try container.decode(Layout.self, forKey: .layout) == .wide {
                    _ = try container.decode(Int.self, forKey: .columns)
                }
            }
        }
        #expect(RecordFieldProbe.probe(LayoutGated.self).branching == [""])

        // A version gate on an integer is flagged the same way, at its own path.
        struct Gated: Decodable {
            enum CodingKeys: String, CodingKey { case version, extra }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if try container.decode(Int.self, forKey: .version) >= 1 {
                    _ = try container.decode(Bool.self, forKey: .extra)
                }
            }
        }
        struct HoldsGated: Decodable { let gated: Gated; let plain: Int }
        let gated = RecordFieldProbe.probe(HoldsGated.self)
        #expect(gated.branching == ["gated"], "the gate's type, not its parent")
        #expect(gated.paths == ["gated", "gated.version", "gated.extra", "plain"])

        // An enum whose raw value the probe can't guess is reported, not skipped.
        enum Mode: String, Decodable { case on }
        struct WithMode: Decodable { let mode: Mode; let after: Int }
        #expect(RecordFieldProbe.probe(WithMode.self).opaque == ["mode"])
        #expect(RecordFieldProbe.probe(WithMode.self, samples: [Mode.on]) == RecordFieldProbeResult(paths: ["mode", "after"]))

        // A sample whose type has fields would hide them: reported, also when the fields sit
        // inside a single value.
        struct Wrapped: Decodable {
            let inner: Inner
            init(inner: Inner) { self.inner = inner }
            init(from decoder: Decoder) throws { inner = try decoder.singleValueContainer().decode(Inner.self) }
        }
        #expect(RecordFieldProbe.probe(WithMode.self, samples: [Mode.on, Inner(x: 0, tags: [])]).nonLeafSamples == ["Inner"])
        let wrapped = Wrapped(inner: Inner(x: 0, tags: []))
        #expect(RecordFieldProbe.probe(WithMode.self, samples: [Mode.on, wrapped]).nonLeafSamples == ["Wrapped"])
        // A boundary is returned unprobed, and where it sits is reported.
        struct WithPayload: Decodable { let payload: AnyCodable; let after: Int }
        #expect(RecordFieldProbe.probe(WithPayload.self, boundaries: [AnyCodable(Int(0))])
            == RecordFieldProbeResult(paths: ["payload", "after"], boundaries: ["payload"]))
    }

    @Test("A recursive type is reported where it recurs, though it stops the fields after it")
    func probeReportsRecursion() {
        final class Node: Decodable { let child: Node?; let after: Int }
        let probe = RecordFieldProbe.probe(Node.self)
        #expect(probe.recursive == ["child"])
        #expect(!probe.paths.contains("after"), "the stop is what the report is for")
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
        autoStartLoops: false,
        landID: landID
    )
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
