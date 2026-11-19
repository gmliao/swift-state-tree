// The raw frames a hybrid land sends, and its record's `eventsNotMerged`, recorded on `main`
// before #521 PR 1b-2a (D10) into `Fixtures/HybridEventFrames/`. Hybrid means `json` or
// `opcodeJsonArray` messages with `opcodeMessagePack` state updates: opcode 107 is on, but no
// event body can be merged into it, so every event goes as its own frame. D10 moves that
// decision to init; the frames and the record must not change.
//
// One file per sync path (`IN_TURN_SYNC`), since the two paths send differently. The legacy
// path records no `eventsNotMerged` (every output's list is empty): its file covers the frames.
// The other environment knobs (sync tables, per-player tables, typed leaf values) are given, not
// read.
//
// A real record of the in-turn path (`hybrid-record.sstr`, `json` messages, event hashes off) is
// committed with them, written by `main`'s code. The record doesn't depend on the message
// encoding: the `opcodeJsonArray` cell writes the same bytes. They are replayed, not compared by bytes: an old
// hybrid record must replay with the same verdict and counts after D10.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

enum HybridEventFrameGoldenEnvKeys {
    /// Set to `1` to rewrite this sync mode's fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_HYBRID_EVENT_FRAMES"
}

@StateNodeBuilder
struct HybridGoldenState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
}

@Payload
struct HybridGoldenEvent: ServerEventPayload {
    let message: String
    let n: Int
}

/// Each tick emits to everyone, to nobody (never queued) and to one player, and requests a sync.
func makeHybridGoldenLand() -> LandDefinition<HybridGoldenState> {
    Land("hybrid-event-frames", using: HybridGoldenState.self) {
        ServerEvents { Register(HybridGoldenEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout HybridGoldenState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(HybridGoldenEvent(message: "all", n: state.ticks), to: .all)
                ctx.emitEvent(HybridGoldenEvent(message: "nobody", n: state.ticks), to: .players([]))
                ctx.emitEvent(HybridGoldenEvent(message: "p1", n: state.ticks), to: .player(PlayerID("p1")))
                ctx.requestSyncNow()
            }
        }
    }
}

private actor HybridGoldenTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(target: String, data: Data)] = []
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        frames.append((String(describing: target), message))
    }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((String(describing: target), data)) }
    }
}

struct HybridGoldenCell: Sendable, CustomStringConvertible {
    let message: TransportEncoding
    let eventHashes: Bool
    var description: String { "\(message.rawValue)|eventHashes=\(eventHashes)" }

    static let all: [HybridGoldenCell] = [TransportEncoding.json, .opcodeJsonArray].flatMap { message in
        [false, true].map { HybridGoldenCell(message: message, eventHashes: $0) }
    }
}

@Suite("Hybrid event frames: the raw frames and eventsNotMerged before D10 (#521 PR 1b-2a)", .serialized)
struct HybridEventFrameGoldenTests {
    static var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HybridEventFrames/hybrid-event-frames-\(InTurnSync.isEnabled() ? "in-turn" : "legacy").json").path
    }

    static let schema: (pathHashes: [String: UInt32], eventHashes: [String: Int]) = {
        let definition = makeHybridGoldenLand()
        let schema = try! SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(definition)])
        let land = schema.lands[definition.id]!
        return (land.pathHashes!, land.eventHashes!)
    }()

    static var recordPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HybridEventFrames/hybrid-record.sstr").path
    }

    /// Two players join, two ticks run, and the adapter sends one event to a client directly.
    /// With `saveRecordTo`, the land's record is saved there as well.
    static func record(_ cell: HybridGoldenCell, saveRecordTo recordPath: String? = nil) async throws -> AnyCodable {
        let keeper = LandKeeper<HybridGoldenState>(
            definition: makeHybridGoldenLand(),
            initialState: HybridGoldenState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        var env = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: false, syncStrategy: .delta, profilingConfig: nil)
        env.useSyncTables = true
        env.perPlayerSyncTables = false
        env.typedLeafValues = true
        let transport = HybridGoldenTransport()
        let adapter = TransportAdapter<HybridGoldenState>(
            keeper: keeper,
            transport: transport,
            landID: "hybrid-event-frames",
            transportEnvConfig: env,
            encodingConfig: TransportEncodingConfig(message: cell.message, stateUpdate: .opcodeMessagePack),
            pathHashes: schema.pathHashes,
            eventHashes: cell.eventHashes ? schema.eventHashes : nil,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        await keeper.awaitInitialization()
        await keeper.setTransport(adapter)
        // `simulateRouterJoin`'s steps, waiting for the writer by its event instead of polling.
        for n in 1 ... 2 {
            let (session, client) = (SessionID("s\(n)"), ClientID("c\(n)"))
            await adapter.onConnect(sessionID: session, clientID: client)
            let decision = try await keeper.join(
                session: PlayerSession(playerID: "p\(n)", deviceID: "dev-mock-p\(n)", metadata: [:]),
                clientID: client, sessionID: session, services: LandServices()
            )
            guard case .allow(let player) = decision else {
                Issue.record("join denied")
                return AnyCodable("join denied")
            }
            await adapter.registerSession(sessionID: session, clientID: client, playerID: player, authInfo: nil)
            _ = await adapter.allocatePlayerSlot(accountKey: player.rawValue, for: player)
            await adapter.syncStateForNewPlayer(playerID: player, sessionID: session)
            await adapter.waitForOutboundIdleForTesting()
        }
        for _ in 0 ..< 2 {
            await keeper.stepTickOnce()
            await adapter.waitForOutboundIdleForTesting()
        }
        await adapter.sendEvent(AnyServerEvent(HybridGoldenEvent(message: "direct", n: 0)), to: .client(ClientID("c1")))
        await adapter.waitForOutboundIdleForTesting()

        // Per target, in send order. The order between sessions follows the adapter's session
        // dictionary, which differs between runs, so it isn't recorded.
        var frames: [String: [AnyCodable]] = [:]
        for frame in await transport.frames {
            var entry: [String: AnyCodable] = ["base64": AnyCodable(frame.data.base64EncodedString())]
            if frame.data.first.map({ $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) == true,
               let text = String(data: frame.data, encoding: .utf8) {
                entry["text"] = AnyCodable(text)
            }
            frames[frame.target, default: []].append(AnyCodable(entry))
        }
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let outputs = ReevaluationSyncStreamEntry.stream(of: await recorder.getAllFrames()).compactMap { entry -> AnyCodable? in
            guard case .output(let o) = entry else { return nil }
            let notMerged = o.eventsNotMerged ?? ReevaluationUnmergedEvents()
            return AnyCodable([
                "turnKind": AnyCodable(String(describing: o.turnKind)),
                "sentAlone": AnyCodable(notMerged.sentAlone.map { AnyCodable(Int($0)) }),
                "lost": AnyCodable(notMerged.lost.map { AnyCodable(Int($0)) }),
            ])
        }
        if let recordPath {
            await recorder.setMetadata(ReevaluationRecordMetadata(
                landID: "hybrid-event-frames",
                landType: "hybrid-event-frames",
                createdAt: Date(timeIntervalSince1970: 0),
                metadata: [:],
                landDefinitionID: makeHybridGoldenLand().id,
                version: ReevaluationRecordVersion.current,
                recordsSyncStream: true,
                syncConfig: adapter.syncConfigForRecord
            ))
            try await recorder.saveCopyForTesting(to: recordPath)
        }
        return AnyCodable([
            "cell": AnyCodable(cell.description),
            "frames": AnyCodable(frames.mapValues { AnyCodable($0) }),
            "eventsNotMerged": AnyCodable(outputs),
        ])
    }

    static func fixture() async throws -> Data {
        var cells: [AnyCodable] = []
        for cell in HybridGoldenCell.all { cells.append(try await record(cell)) }
        let document: [String: AnyCodable] = [
            "inTurnSync": AnyCodable(InTurnSync.isEnabled()),
            "cells": AnyCodable(cells),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document) + Data("\n".utf8)
    }

    @Test("The fixture for this sync mode is current")
    func fixtureIsCurrent() async throws {
        let data = try await Self.fixture()
        if EnvHelpers.getEnvBool(key: HybridEventFrameGoldenEnvKeys.regenerate, defaultValue: false) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Self.fixturePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            if InTurnSync.isEnabled() {
                _ = try await Self.record(HybridGoldenCell(message: .json, eventHashes: false), saveRecordTo: Self.recordPath)
            }
            return
        }
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(data == committed, "regenerate with \(HybridEventFrameGoldenEnvKeys.regenerate)=1, and say why in the PR")
    }

    /// What `main`'s code gives for the committed records, before D10.
    static let expectedVerdict: SyncOutputVerdict = .partial
    static let expectedEvents = SyncOutputScopeCounts(compared: 0, unverifiable: 2, skipped: 0)

    @Test("An old hybrid record replays: its state hashes and events match, and every event counts as sent alone")
    func oldRecordReplays() async throws {
        let result = try await ReevaluationEngine.run(
            definition: makeHybridGoldenLand(),
            initialState: HybridGoldenState(),
            recordFilePath: Self.recordPath
        )
        #expect(result.maxTickId == 1)
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil }
            == result.recordedStateHashes)
        #expect(result.serverEventMismatches.isEmpty)
        let sync = result.syncOutput
        #expect((sync.eventsSentAlone, sync.eventsLost) == (6, 0), "\(sync.summary)")
        #expect(sync.verdict == Self.expectedVerdict, "\(sync.summary)")
        #expect(sync.events == Self.expectedEvents, "\(sync.summary)")
    }

    @Test("Recording twice gives the same bytes")
    func recordingIsStable() async throws {
        #expect(try await Self.fixture() == Self.fixture())
    }
}
