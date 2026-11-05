// Tests/SwiftStateTreeTransportTests/SyncStreamProducerTests.swift
//
// Record format 2.1, live side: the sync outputs and markers the adapter records while in-turn
// sync is on, and that nothing is recorded (or computed) otherwise.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct SyncStreamTestState: StateNodeProtocol {
    @Sync(.broadcast) var ticks: Int = 0
    init() {}
}

@Payload
struct SyncStreamTestEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

/// Each tick increments `ticks`, emits one event to everyone and requests a sync.
private func makeSyncStreamLand() -> LandDefinition<SyncStreamTestState> {
    Land("sync-stream-test", using: SyncStreamTestState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout SyncStreamTestState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(SyncStreamTestEvent(message: "tick-\(state.ticks)"), to: .all)
                ctx.requestSyncNow()
            }
        }
    }
}

private let syncStreamPathHashes: [String: UInt32] = ["ticks": DeterministicHash.fnv1a32("ticks")]

private actor SyncStreamTransport: Transport {
    var delegate: TransportDelegate?
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {}
}

private struct SyncStreamFixture {
    let keeper: LandKeeper<SyncStreamTestState>
    let adapter: TransportAdapter<SyncStreamTestState>
    let session = SessionID("sst-session")
    let client = ClientID("sst-client")
    let player = PlayerID("sst-player")

    static func make(encoding: InTurnEncoding, inTurn: Bool = true, recording: Bool = true) async -> SyncStreamFixture {
        let keeper = LandKeeper<SyncStreamTestState>(
            definition: makeSyncStreamLand(),
            initialState: SyncStreamTestState(),
            enableLiveStateHashRecording: recording,
            autoStartLoops: false
        )
        let transport = SyncStreamTransport()
        let adapter = TransportAdapter<SyncStreamTestState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-stream-test",
            encodingConfig: encoding.config,
            pathHashes: encoding == .json ? nil : syncStreamPathHashes,
            inTurnSync: inTurn
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        return SyncStreamFixture(keeper: keeper, adapter: adapter)
    }

    func join() async throws {
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
    }

    func tick() async {
        await keeper.stepTickOnce()
        #expect(await adapter.waitForOutboundDrain())
    }

    /// The recorded sync stream, after every submission so far.
    func stream() async throws -> [ReevaluationSyncStreamEntry] {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        return ReevaluationSyncStreamEntry.stream(of: await recorder.getAllFrames())
    }
}

private func outputs(_ stream: [ReevaluationSyncStreamEntry]) -> [ReevaluationRecordedSyncOutput] {
    stream.compactMap { if case .output(let output) = $0 { return output } else { return nil } }
}

private func markers(_ stream: [ReevaluationSyncStreamEntry]) -> [ReevaluationRecordedSyncMarker] {
    stream.compactMap { if case .marker(let marker) = $0 { return marker } else { return nil } }
}

private func ticksPatch(_ value: Int) -> UInt64 {
    CanonicalPatchList([StatePatch(path: "/ticks", operation: .set(.int(value)))]).hash
}

@Suite("Sync stream producer (record format 2.1)", .timeLimit(.minutes(1)))
struct SyncStreamProducerTests {
    @Test("A join records a seed, each tick turn an output with the broadcast diff's hash", arguments: InTurnEncoding.allCases)
    func seedThenTickOutputs(encoding: InTurnEncoding) async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture.make(encoding: encoding)
        try await f.join()
        await f.tick()
        await f.tick()
        let stream = try await f.stream()
        #expect(stream.map(\.streamIndex) == Array(0 ..< UInt64(stream.count)), "contiguous, in stream order")

        let seeds = markers(stream)
        #expect(seeds.count == 1)
        let seed = try #require(seeds.first)
        #expect(seed.kind == .seed)
        #expect(seed.playerID == f.player.rawValue)
        #expect(seed.rejoin == false)
        #expect(seed.observedTickId == -1, "the firstSync read state before tick 0")
        #expect(seed.viewHash == CanonicalPatchList([StatePatch(path: "/ticks", operation: .set(.int(0)))]).hash)

        let ticks = outputs(stream).filter { $0.turnKind == .tick }
        #expect(ticks.map(\.observedTickId) == [0, 1])
        #expect(ticks.map(\.index) == [0, 0])
        #expect(ticks.map(\.broadcastHash) == [ticksPatch(1), ticksPatch(2)])
        #expect(ticks.allSatisfy { $0.extractionDrops.isEmpty && $0.encodeDropScopes.isEmpty })
        // json / opcodeJsonArray send one combined update per player (broadcast included); opcode
        // 107 sends the broadcast in the merged frame, and this land has no per-player field.
        #expect(ticks.allSatisfy { ($0.perPlayerHash != nil) == (encoding != .messagepack) })
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
        if encoding == .messagepack {
            // Opcode 107 queues events: each tick's output hashes the one event it consumed.
            #expect(ticks.allSatisfy { $0.eventsHash != nil })
            #expect(ticks[0].eventsHash != ticks[1].eventsHash)
        } else {
            #expect(ticks.allSatisfy { $0.eventsHash == nil })
        }
    }

    @Test("The events hash is the consumed events' canonical hash, with the keeper sequence")
    func eventsHashUsesKeeperSequence() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture.make(encoding: .messagepack)
        try await f.join()
        await f.tick()
        let recorder = try #require(await f.keeper.getReevaluationRecorder())
        await f.keeper.waitForRecorderSubmissionsForTesting()
        let frame = try #require(await recorder.getAllFrames().first { $0.tickId == 0 })
        let event = try #require(frame.serverEvents.first)
        let output = try #require(frame.syncOutputs.first { $0.turnKind == .tick })
        let expected = CanonicalSyncEvent(
            sequence: event.sequence,
            type: event.typeIdentifier,
            payload: .object(["message": .string("tick-1")])
        )
        #expect(output.eventsHash == CanonicalSyncEvent.hash([expected]))
    }

    @Test("A disconnect records a clear; the reconnect's seed is a rejoin")
    func clearAndRejoin() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture.make(encoding: .json)
        try await f.join()
        await f.tick()
        await f.adapter.onDisconnect(sessionID: f.session, clientID: f.client)
        try await f.join()
        let found = markers(try await f.stream())
        #expect(found.map(\.kind) == [.seed, .clear, .seed])
        #expect(found.map(\.playerID) == Array(repeating: f.player.rawValue, count: 3))
        #expect(found.map(\.rejoin) == [false, false, true])
        #expect(found.last?.observedTickId == 0, "the rejoin read state after tick 0")
    }

    @Test("A firstSync read after a tick ran since the join is located at that tick")
    func firstSyncLocatedAfterTick() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture.make(encoding: .json)
        // Join without the firstSync, run a tick turn, then send the firstSync: its state read
        // and its position come from one keeper job, so the seed names tick 0, never -1.
        await f.adapter.onConnect(sessionID: f.session, clientID: f.client)
        _ = try await f.keeper.join(
            session: PlayerSession(playerID: f.player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: f.client,
            sessionID: f.session,
            services: LandServices()
        )
        await f.adapter.registerSession(sessionID: f.session, clientID: f.client, playerID: f.player, authInfo: nil)
        await f.keeper.stepTickOnce()
        await f.adapter.syncStateForNewPlayer(playerID: f.player, sessionID: f.session)
        let seed = try #require(markers(try await f.stream()).first { $0.kind == .seed })
        #expect(seed.observedTickId == 0)
        #expect(seed.viewHash == CanonicalPatchList([StatePatch(path: "/ticks", operation: .set(.int(1)))]).hash)
    }

    @Test("Off path records nothing: in-turn sync off with a recorder", arguments: InTurnEncoding.allCases)
    func offPathRecordsNothing(encoding: InTurnEncoding) async throws {
        let f = await SyncStreamFixture.make(encoding: encoding, inTurn: false)
        try await f.join()
        await f.tick()
        await f.tick()
        #expect(try await f.stream().isEmpty)
        #expect(await f.keeper.syncStreamCounterForTesting() == 0)
        #expect(await f.adapter.syncOutputDigestCountForTesting == 0)
    }

    @Test("No recorder, no work: in-turn sync on without a recorder", arguments: InTurnEncoding.allCases)
    func noRecorderNoWork(encoding: InTurnEncoding) async throws {
        let f = await SyncStreamFixture.make(encoding: encoding, recording: false)
        try await f.join()
        await f.tick()
        await f.tick()
        #expect(await f.keeper.getReevaluationRecorder() == nil)
        #expect(await f.keeper.syncStreamCounterForTesting() == 0)
        #expect(await f.adapter.syncOutputDigestCountForTesting == 0)
    }
}

@Suite("Located reads", .timeLimit(.minutes(1)))
struct LocatedReadTests {
    @Test("State and position come from one keeper job, even when a tick turn runs between two reads")
    func locatedReadIsOnePoint() async throws {
        let keeper = LandKeeper<SyncStreamTestState>(
            definition: makeSyncStreamLand(),
            initialState: SyncStreamTestState(),
            autoStartLoops: false
        )
        await keeper.stepTickOnce()
        // Two separate reads with a tick turn between them describe two different points.
        let separateState = await keeper.currentState()
        await keeper.stepTickOnce()
        let separateTick = await keeper.debugLastCommittedTickId()
        #expect(Int64(separateState.ticks) != separateTick + 1, "the separate reads disagree")
        // The located read: the state after tick N has ticks == N + 1.
        let located = await keeper.currentStateLocated()
        #expect(Int64(located.state.ticks) == located.position.observedTickId + 1)
        await keeper.stepTickOnce()
        let begun = try #require(await keeper.beginSyncLocated(clearDirtyFlags: false))
        #expect(Int64(begun.state.ticks) == begun.position.observedTickId + 1)
        #expect(begun.position.observedTickId == located.position.observedTickId + 1)
        #expect(begun.position.sequence > located.position.sequence)
        await keeper.endSync()
    }
}
