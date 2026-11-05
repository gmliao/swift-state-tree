// Tests/SwiftStateTreeTests/ReevaluationSyncStreamTests.swift
//
// Record format 2.1: the sync stream in tick frames, its order, and absent vs empty.

import Foundation
import Testing
@testable import SwiftStateTree

private func output(_ streamIndex: UInt64, observed: Int64?, kind: ReevaluationRecordedSyncOutput.TurnKind = .syncOnly) -> ReevaluationRecordedSyncOutput {
    ReevaluationRecordedSyncOutput(
        index: 0,
        turnKind: kind,
        observedTickId: observed,
        streamIndex: streamIndex,
        sequence: 0,
        broadcastHash: 42
    )
}

private func metadata(version: String?, recordsSyncStream: Bool?) -> ReevaluationRecordMetadata {
    ReevaluationRecordMetadata(
        landID: "sync-stream:local",
        landType: "sync-stream",
        createdAt: Date(timeIntervalSince1970: 0),
        metadata: [:],
        version: version,
        recordsSyncStream: recordsSyncStream
    )
}

private func emptyFrame(_ tickId: Int64) -> ReevaluationTickFrame {
    ReevaluationTickFrame(tickId: tickId, actions: [], clientEvents: [], lifecycleEvents: [])
}

@Suite("Re-evaluation sync stream records")
struct ReevaluationSyncStreamTests {
    @Test("A 2.0 frame decodes with an empty sync stream and no initialize record")
    func oldFrameDecodes() throws {
        let json = #"{"tickId":3,"actions":[],"clientEvents":[],"lifecycleEvents":[]}"#
        let frame = try JSONDecoder().decode(ReevaluationTickFrame.self, from: Data(json.utf8))
        #expect(frame.syncOutputs.isEmpty)
        #expect(frame.syncMarkers.isEmpty)
        #expect(frame.initialize == nil)
    }

    @Test("A frame without a sync stream encodes without the new keys")
    func emptyStreamOmitted() throws {
        let data = try JSONEncoder().encode(emptyFrame(0))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("syncOutputs"))
        #expect(!text.contains("syncMarkers"))
        #expect(!text.contains("initialize"))
    }

    @Test("Outputs, markers and the initialize record round-trip")
    func roundTrip() throws {
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [],
            clientEvents: [],
            lifecycleEvents: [],
            syncOutputs: [output(1, observed: -1, kind: .tick)],
            syncMarkers: [
                ReevaluationRecordedSyncMarker(kind: .initialize, streamIndex: 0, sequence: 0),
                ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p1", observedTickId: 0, streamIndex: 2, sequence: 4, rejoin: true, viewHash: 7),
            ],
            initialize: ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: "abc")
        )
        let decoded = try JSONDecoder().decode(ReevaluationTickFrame.self, from: try JSONEncoder().encode(frame))
        #expect(decoded.syncOutputs == frame.syncOutputs)
        #expect(decoded.syncMarkers == frame.syncMarkers)
        #expect(decoded.initialize?.stateHash == "abc")
        #expect(decoded.initialize?.sequence == 0)
    }

    @Test("Stream order is streamIndex alone, not array position or tick")
    func streamOrder() {
        // Frame 0: the initialize marker and a sync-only output before tick 0 (observedTickId -1),
        // listed out of stream order; frame 1 holds an output numbered before one of frame 0's.
        var frame0 = emptyFrame(0)
        frame0 = frame0.replacing(
            syncOutputs: [output(3, observed: -1), output(0, observed: -1)],
            syncMarkers: [ReevaluationRecordedSyncMarker(kind: .initialize, streamIndex: 1, sequence: 0)]
        )
        let frame1 = emptyFrame(1).replacing(syncOutputs: [output(2, observed: 0, kind: .tick)])
        let stream = ReevaluationSyncStreamEntry.stream(of: [frame1, frame0])
        #expect(stream.map(\.streamIndex) == [0, 1, 2, 3])
        guard case .output(let first) = stream[0], case .marker(let second) = stream[1] else {
            Issue.record("expected the sync-only output, then the initialize marker")
            return
        }
        #expect(first.observedTickId == -1)
        #expect(second.kind == .initialize)
    }

    @Test("Turn records merge their sync stream into the frame")
    func recorderMerges() async {
        let recorder = ReevaluationRecorder()
        await recorder.recordTick(ReevaluationTickRecord(tickId: 0, syncMarkers: [
            ReevaluationRecordedSyncMarker(kind: .initialize, streamIndex: 0, sequence: 0),
        ]))
        await recorder.recordTick(ReevaluationTickRecord(tickId: 0, syncOutputs: [output(1, observed: -1)]))
        await recorder.recordTick(ReevaluationTickRecord(tickId: 1, syncOutputs: [output(2, observed: 0)]))
        await recorder.recordTick(ReevaluationTickRecord(tickId: 0, syncOutputs: [output(3, observed: 0)]))
        let frames = await recorder.getAllFrames()
        let frame0 = frames.first { $0.tickId == 0 }
        #expect(frame0?.syncMarkers.count == 1)
        #expect(frame0?.syncOutputs.map(\.streamIndex) == [1, 3])
        #expect(frames.first { $0.tickId == 1 }?.syncOutputs.map(\.streamIndex) == [2])
    }

    @Test("Absent and empty are different: the header decides")
    func presence() async throws {
        let empty = [emptyFrame(0)]
        let cases: [(Bool?, String?, ReevaluationSyncStreamPresence)] = [
            (nil, "2.0", .absent(reason: "record version 2.0 predates sync-output recording")),
            (nil, nil, .absent(reason: "record version unknown predates sync-output recording")),
            (false, "2.1", .absent(reason: "recorded with in-turn sync off")),
            (true, "2.1", .recorded(outputs: 0, markers: 0)),
        ]
        for (flag, version, expected) in cases {
            let source = JSONReevaluationSource(metadata: metadata(version: version, recordsSyncStream: flag), frames: empty)
            #expect(try await source.getSyncStreamPresence() == expected)
        }
        let withStream = [emptyFrame(0).replacing(
            syncOutputs: [output(0, observed: -1)],
            syncMarkers: [ReevaluationRecordedSyncMarker(kind: .initialize, streamIndex: 1, sequence: 0)]
        )]
        let source = JSONReevaluationSource(metadata: metadata(version: "2.1", recordsSyncStream: true), frames: withStream)
        #expect(try await source.getSyncStreamPresence() == .recorded(outputs: 1, markers: 1))
    }
}

@Suite("Re-evaluation sync hashes in JSON")
struct ReevaluationSyncHashCodingTests {
    /// Above 2^53: a JSON number this large does not survive a reader that parses numbers as
    /// doubles (JavaScript, `JSONSerialization`).
    private static let large: UInt64 = 2_469_563_164_985_495_381

    private static let sample = ReevaluationRecordedSyncOutput(
        index: 0,
        turnKind: .tick,
        observedTickId: 3,
        streamIndex: 7,
        sequence: 11,
        broadcastHash: large,
        perPlayerHash: UInt64.max,
        perPlayerHashes: ["p1": 1],
        eventsHash: 0
    )

    @Test("Hashes are written as 16 hex digits and survive a double-based JSON reader")
    func hexSurvivesDoubleReaders() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["broadcastHash"] as? String == "2245a69d3f598f55")
        #expect(object["perPlayerHash"] as? String == "ffffffffffffffff")
        #expect(object["eventsHash"] as? String == "0000000000000000")
        #expect((object["perPlayerHashes"] as? [String: String])?["p1"] == "0000000000000001")
        // Through a double-based reader and back: unchanged.
        let roundTripped = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ReevaluationRecordedSyncOutput.self, from: roundTripped) == Self.sample)

        let marker = ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p1", observedTickId: -1, streamIndex: 0, sequence: 1, viewHash: Self.large)
        let markerData = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: JSONEncoder().encode(marker)))
        #expect(try JSONDecoder().decode(ReevaluationRecordedSyncMarker.self, from: markerData).viewHash == Self.large)
    }

    @Test("The RNG seed is written as hex and read from hex or a number")
    func rngSeedIsHex() throws {
        let metadata = ReevaluationRecordMetadata(landID: "l", landType: "t", createdAt: Date(timeIntervalSince1970: 0), metadata: [:], rngSeed: Self.large)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(metadata)) as? [String: Any])
        #expect(object["rngSeed"] as? String == "2245a69d3f598f55")
        let roundTripped = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(ReevaluationRecordMetadata.self, from: roundTripped).rngSeed == Self.large)
        let numeric = #"{"landID":"l","landType":"t","createdAt":"1970-01-01T00:00:00Z","metadata":{},"rngSeed":2469563164985495381}"#
        #expect(try decoder.decode(ReevaluationRecordMetadata.self, from: Data(numeric.utf8)).rngSeed == Self.large)
        let absent = #"{"landID":"l","landType":"t","createdAt":"1970-01-01T00:00:00Z","metadata":{}}"#
        #expect(try decoder.decode(ReevaluationRecordMetadata.self, from: Data(absent.utf8)).rngSeed == nil)
    }

    @Test("A 2.1 record's numeric hashes still decode")
    func numericHashesDecode() throws {
        let json = #"{"index":0,"turnKind":"tick","observedTickId":3,"streamIndex":7,"sequence":11,"broadcastHash":2469563164985495381,"extractionDrops":{},"encodeDropScopes":[]}"#
        let output = try JSONDecoder().decode(ReevaluationRecordedSyncOutput.self, from: Data(json.utf8))
        #expect(output.broadcastHash == Self.large)
        let marker = #"{"kind":"seed","streamIndex":0,"sequence":1,"rejoin":false,"viewHash":2469563164985495381}"#
        #expect(try JSONDecoder().decode(ReevaluationRecordedSyncMarker.self, from: Data(marker.utf8)).viewHash == Self.large)
    }
}

@Suite("Sync stream recording detail")
struct SyncStreamRecordingDetailTests {
    @Test("The environment turns each detail on; both are off by default")
    func fromEnvironment() {
        #expect(SyncStreamRecordingDetail.fromEnvironment([:]).isEmpty)
        #expect(SyncStreamRecordingDetail.fromEnvironment([EnvKeys.Reevaluation.recordSyncDetails: "true"]) == .perPlayerHashes)
        #expect(SyncStreamRecordingDetail.fromEnvironment([EnvKeys.Reevaluation.recordSyncPatches: "true"]) == .patches)
        #expect(SyncStreamRecordingDetail.fromEnvironment([
            EnvKeys.Reevaluation.recordSyncDetails: "true",
            EnvKeys.Reevaluation.recordSyncPatches: "true",
        ]) == [.perPlayerHashes, .patches])
    }

    @Test("A seed's dropped view fields survive a round trip, and are absent when none dropped")
    func viewDropFieldsRoundTrip() throws {
        let degraded = ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p", observedTickId: 0, streamIndex: 0, sequence: 1, viewDrops: [.extraction], viewDropFields: ["fragile"])
        let full = ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p", observedTickId: 0, streamIndex: 1, sequence: 1, viewHash: 7)
        for marker in [degraded, full] {
            let data = try JSONEncoder().encode(marker)
            #expect(try JSONDecoder().decode(ReevaluationRecordedSyncMarker.self, from: data) == marker)
        }
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        #expect(object["viewDropFields"] == nil)
    }
}
