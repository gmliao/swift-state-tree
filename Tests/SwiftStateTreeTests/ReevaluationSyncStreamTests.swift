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
