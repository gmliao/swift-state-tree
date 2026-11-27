// Tests/SwiftStateTreeTransportTests/PortlessInitializeRecordTests.swift
//
// #546 L2d-2: a live keeper whose OnInitialize runs before its transport is attached (a hosted
// land initialized before `LandManager`'s `.wiring`, which is every land without an init
// resolver). The records in Fixtures/ReplayCompatibility/portless-initialize-*.reeval.sstr were
// made by the build before L2d-2 from `PortlessInitializeScenario`; they must keep replaying, and
// the same scenario recorded now must decode the same, frame by frame (a portless keeper records
// no sync stream, so its turn-path initialize adds no marker).

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// The tickless verifier land with an OnInitialize that emits an event (`makeTicklessVerifierLand`
/// has none).
func makeTicklessInitVerifierLand() -> LandDefinition<VerifierState> {
    Land("sync-output-verifier-tickless-init-test", using: VerifierState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Rules {
            HandleAction(VerifierSetAction.self) { state, action, ctx in
                state.scores[ctx.playerID] = action.value
                ctx.requestSyncNow()
                return SyncStreamSetResponse(ok: true)
            }
        }
        Lifetime {
            OnInitialize { state, ctx in
                ctx.emitEvent(SyncStreamTestEvent(message: "init"), to: .all)
            }
        }
    }
}

enum PortlessInitializeScenario {
    static func name(tick: Bool) -> String {
        tick ? "portless-initialize-tick" : "portless-initialize-tickless"
    }

    static func definition(tick: Bool) -> LandDefinition<VerifierState> {
        tick ? makeVerifierLand() : makeTicklessInitVerifierLand()
    }

    /// OnInitialize with no transport, then the attach, a join, an action and a sync (two ticks on
    /// the tick land). Every step is the test's, so two runs of one build record the same.
    static func run(tick: Bool) async throws -> VerifierFixture {
        let f = await VerifierFixture.make(encoding: .messagepack, initializeFirst: true, definition: definition(tick: tick))
        try await f.join(1)
        try await f.set(1, "a", 3)
        if tick {
            await f.tick(2)
        } else {
            await f.adapter.syncNow()
            await f.adapter.waitForOutboundIdleForTesting()
        }
        return f
    }

    static func record(tick: Bool, to path: String) async throws {
        let f = try await run(tick: tick)
        try await f.saveRecord(to: path)
    }

    /// The record's frames as canonical JSON, one string per frame, each payload as its tree: the
    /// record before L2d-2 holds trees, and one made now holds bytes (#700 K1a).
    static func decodedFrames(atPath path: String) throws -> [String] {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("portless-initialize-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: copy) }
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: copy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(FramesOnly.self, from: Data(contentsOf: URL(fileURLWithPath: copy)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try file.tickFrames.map {
            String(decoding: try RecordedPayloadTree.treeForm(frameJSON: encoder.encode($0)), as: UTF8.self)
        }
    }

    private struct FramesOnly: Codable {
        var tickFrames: [ReevaluationTickFrame]
    }
}

@Suite("Portless initialize: records across #546 L2d-2", .timeLimit(.minutes(1)), .resolverDeadlinesOff, .drainsFixtureKeepers)
struct PortlessInitializeRecordTests {
    /// Every state hash the record holds is reproduced. A tickless land records none per tick (its
    /// replay still hashes tick 0); the tick land records one per tick.
    static func expectRecordedHashesReproduced(_ result: ReevaluationEngine.RunResult, tick: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        if tick { #expect(!result.recordedStateHashes.isEmpty, sourceLocation: sourceLocation) }
        for (tickId, hash) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == hash, "state hash of tick \(tickId)", sourceLocation: sourceLocation)
        }
    }

    /// Writes the scenario's records to `PORTLESS_INITIALIZE_RECORD_DIR` (how the fixtures were made).
    @Test(
        "Writes the portless-initialize records",
        .enabled(if: ProcessInfo.processInfo.environment["PORTLESS_INITIALIZE_RECORD_DIR"] != nil),
        arguments: [false, true]
    )
    func writeRecords(tick: Bool) async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["PORTLESS_INITIALIZE_RECORD_DIR"])
        let path = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(PortlessInitializeScenario.name(tick: tick)).reeval.sstr").path
        try await PortlessInitializeScenario.record(tick: tick, to: path)
    }

    @Test("The record made before L2d-2 replays: every hash reproduced, sync outputs and initialize verified", arguments: [false, true])
    func baseRecordReplays(tick: Bool) async throws {
        let path = ReplayCompatibilityRecordTests.path(PortlessInitializeScenario.name(tick: tick))
        let result = try await ReplayCompatibilityRecordTests.replayUpgraded(path, definition: PortlessInitializeScenario.definition(tick: tick))
        Self.expectRecordedHashesReproduced(result, tick: tick)
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.initialize == .passed)
    }

    @Test("The scenario recorded now replays: every hash reproduced, sync outputs and initialize verified", arguments: [false, true])
    func newRecordReplays(tick: Bool) async throws {
        let f = try await PortlessInitializeScenario.run(tick: tick)
        let result = try await f.replay()
        Self.expectRecordedHashesReproduced(result, tick: tick)
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.initialize == .passed)
    }

    @Test("The scenario recorded now decodes as the record made before L2d-2", arguments: [false, true])
    func decodedAsBase(tick: Bool) async throws {
        let base = try PortlessInitializeScenario.decodedFrames(
            atPath: ReplayCompatibilityRecordTests.path(PortlessInitializeScenario.name(tick: tick))
        )
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("portless-initialize-now-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await PortlessInitializeScenario.record(tick: tick, to: path)
        let now = try PortlessInitializeScenario.decodedFrames(atPath: path)
        #expect(now.count == base.count)
        for (index, pair) in zip(now, base).enumerated() {
            #expect(pair.0 == pair.1, "frame \(index)")
        }
    }
}
