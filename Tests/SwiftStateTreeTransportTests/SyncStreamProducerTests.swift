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

private struct SyncStreamFixture<S: StateNodeProtocol> {
    let keeper: LandKeeper<S>
    let adapter: TransportAdapter<S>
    let session = SessionID("sst-session")
    let client = ClientID("sst-client")
    let player = PlayerID("sst-player")

    static func make(encoding: InTurnEncoding, inTurn: Bool = true, recording: Bool = true) async -> SyncStreamFixture<SyncStreamTestState> {
        await SyncStreamFixture<SyncStreamTestState>.make(
            definition: makeSyncStreamLand(),
            initialState: SyncStreamTestState(),
            encoding: encoding,
            pathHashes: syncStreamPathHashes,
            inTurn: inTurn,
            recording: recording
        )
    }

    /// With `encoder`, the adapter encodes json through it (it ignores `encoding`).
    static func make(
        definition: LandDefinition<S>,
        initialState: S,
        encoding: InTurnEncoding,
        pathHashes: [String: UInt32],
        encoder: (any StateUpdateEncoder)? = nil,
        inTurn: Bool = true,
        recording: Bool = true
    ) async -> SyncStreamFixture<S> {
        let keeper = LandKeeper<S>(
            definition: definition,
            initialState: initialState,
            enableLiveStateHashRecording: recording,
            autoStartLoops: false
        )
        let transport = SyncStreamTransport()
        let adapter: TransportAdapter<S>
        if let encoder {
            adapter = TransportAdapter<S>(
                keeper: keeper,
                transport: transport,
                landID: "sync-stream-test",
                stateUpdateEncoder: encoder,
                inTurnSync: inTurn
            )
        } else {
            adapter = TransportAdapter<S>(
                keeper: keeper,
                transport: transport,
                landID: "sync-stream-test",
                encodingConfig: encoding.config,
                pathHashes: encoding == .json ? nil : pathHashes,
                inTurnSync: inTurn
            )
        }
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        return SyncStreamFixture<S>(keeper: keeper, adapter: adapter)
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
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: encoding)
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
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: .messagepack)
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
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: .json)
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
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: .json)
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
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: encoding, inTurn: false)
        try await f.join()
        await f.tick()
        await f.tick()
        #expect(try await f.stream().isEmpty)
        #expect(await f.keeper.syncStreamCounterForTesting() == 0)
        #expect(await f.adapter.syncOutputDigestCountForTesting == 0)
    }

    @Test("No recorder, no work: in-turn sync on without a recorder", arguments: InTurnEncoding.allCases)
    func noRecorderNoWork(encoding: InTurnEncoding) async throws {
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: encoding, recording: false)
        try await f.join()
        await f.tick()
        await f.tick()
        #expect(await f.keeper.getReevaluationRecorder() == nil)
        #expect(await f.keeper.syncStreamCounterForTesting() == 0)
        #expect(await f.adapter.syncOutputDigestCountForTesting == 0)
    }
}

// MARK: - Drops, legacy cycles and stream order

/// A value whose snapshot conversion throws while `broken` is set (an extraction drop).
struct SyncStreamFragile: Codable, Sendable, Equatable, SnapshotValueConvertible {
    var broken = false
    func toSnapshotValue() throws -> SnapshotValue {
        if broken { throw SyncStreamFault() }
        return .int(0)
    }
}

struct SyncStreamFault: Error {}

@StateNodeBuilder
struct SyncStreamDropState: StateNodeProtocol {
    @Sync(.broadcast) var ticks: Int = 0
    @Sync(.broadcast) var fragile = SyncStreamFragile()
    @Sync(.perPlayerSlice()) var speeds: [PlayerID: Double] = [:]
    init() {}
}

/// "break" / "fix": broadcast `fragile`; "inf": the caller's `speeds` entry is infinity (json
/// cannot encode it); "speed": the caller's entry is `value`.
@Payload
struct SyncStreamSetAction: ActionPayload {
    typealias Response = SyncStreamSetResponse
    let field: String
    let value: Int
}

@Payload
struct SyncStreamSetResponse: ResponsePayload {
    let ok: Bool
}

private func makeSyncStreamDropLand() -> LandDefinition<SyncStreamDropState> {
    Land("sync-stream-drop-test", using: SyncStreamDropState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout SyncStreamDropState, ctx: LandContext) in
                state.ticks += 1
                ctx.requestSyncNow()
            }
        }
        Rules {
            HandleAction(SyncStreamSetAction.self) { (state: inout SyncStreamDropState, action: SyncStreamSetAction, ctx: LandContext) in
                switch action.field {
                case "break": state.fragile.broken = true
                case "fix": state.fragile.broken = false
                case "inf": state.speeds[ctx.playerID] = .infinity
                default: state.speeds[ctx.playerID] = Double(action.value)
                }
                return SyncStreamSetResponse(ok: true)
            }
        }
    }
}

private let syncStreamDropPathHashes: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: ["ticks", "fragile", "speeds"].map { ($0, DeterministicHash.fnv1a32($0)) }
)

/// A switch the tests flip from outside the adapter.
private final class SyncStreamSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
}

/// JSON, except that every per-player update fails while `fails` is on (even an empty one).
private struct SyncStreamFailingEncoder: StateUpdateEncoderWithScope {
    let inner = JSONStateUpdateEncoder()
    let fails: SyncStreamSwitch

    var encoding: StateUpdateEncoding { inner.encoding }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: nil, scope: .perPlayer)
    }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: .perPlayer)
    }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?, scope: StateUpdateKeyScope) throws -> Data {
        if case .perPlayer = scope, fails.isOn { throw SyncStreamFault() }
        return try inner.encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot)
    }
}

extension SyncStreamFixture where S == SyncStreamDropState {
    static func makeDrop(encoder: (any StateUpdateEncoder)? = nil) async -> SyncStreamFixture<SyncStreamDropState> {
        await make(
            definition: makeSyncStreamDropLand(),
            initialState: SyncStreamDropState(),
            encoding: .json,
            pathHashes: syncStreamDropPathHashes,
            encoder: encoder
        )
    }

    func set(_ field: String, _ value: Int = 0) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: SyncStreamSetAction.self),
                payload: AnyCodable(SyncStreamSetAction(field: field, value: value))
            ),
            playerID: player,
            clientID: client,
            sessionID: session
        )
    }

    /// Joins and registers the session without the firstSync.
    func joinWithoutFirstSync() async throws {
        await adapter.onConnect(sessionID: session, clientID: client)
        _ = try await keeper.join(
            session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: client,
            sessionID: session,
            services: LandServices()
        )
        await adapter.registerSession(sessionID: session, clientID: client, playerID: player, authInfo: nil)
    }
}

@Suite("Sync stream producer: drops, legacy cycles, order", .timeLimit(.minutes(1)))
struct SyncStreamProducerDropTests {
    @Test("An extraction drop is recorded on the output, and on a firstSync seed as an unverifiable view")
    func extractionDrops() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture<SyncStreamDropState>.makeDrop()
        try await f.join()
        try await f.set("break")
        await f.tick()  // inputs apply in the tick turn: `fragile` stops extracting
        // A second player joins: its firstSync view leaves `fragile` out.
        let second = PlayerID("sst-player-2")
        await f.adapter.onConnect(sessionID: SessionID("sst-session-2"), clientID: ClientID("sst-client-2"))
        try await simulateRouterJoin(
            adapter: f.adapter,
            keeper: f.keeper,
            sessionID: SessionID("sst-session-2"),
            clientID: ClientID("sst-client-2"),
            playerID: second
        )
        let stream = try await f.stream()
        let seeds = markers(stream).filter { $0.kind == .seed }
        #expect(seeds.map(\.playerID) == [f.player.rawValue, second.rawValue])
        #expect(seeds[0].viewDrops.isEmpty)
        #expect(seeds[0].viewHash != nil)
        #expect(seeds[1].viewHash == nil)
        #expect(seeds[1].viewDrops == [.extraction])
        #expect(seeds[1].observedTickId == 0)
        let tick = try #require(outputs(stream).first { $0.turnKind == .tick })
        #expect(tick.extractionDrops == ["broadcast": ["fragile"]])
        #expect(tick.encodeDropScopes.isEmpty)
    }

    @Test("An encode drop is recorded on the output, and on a degraded full-view seed as an unverifiable view")
    func encodeDrops() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture<SyncStreamDropState>.makeDrop()
        // Registered without a firstSync: tick 0's plan sends the player its full view, and the
        // infinite speed set in that turn does not encode, so the view goes out degraded.
        try await f.joinWithoutFirstSync()
        try await f.set("inf")
        await f.tick()
        let seed = try #require(markers(try await f.stream()).first { $0.kind == .seed })
        #expect(seed.viewHash == nil, "the client got the view without the infinite speed")
        #expect(seed.viewDrops == [.encode])
        #expect(seed.observedTickId == 0)
        #expect(seed.rejoin == false)

        try await f.set("speed", 3)
        await f.tick()
        try await f.set("inf")
        await f.tick()
        let ticks = outputs(try await f.stream()).filter { $0.turnKind == .tick }
        #expect(ticks.map(\.encodeDropScopes) == [[f.player.rawValue], [], [f.player.rawValue]])
        #expect(ticks[0].perPlayerHash == nil, "the seed replaces the player's per-player scope")
        #expect(ticks[1].perPlayerHash != nil)
        #expect(ticks[2].perPlayerHash != nil, "the frame without the dropped patch was committed")
    }

    @Test("A full view that fails to encode entirely records no seed; the next real seed is not a rejoin")
    func noPhantomSeed() async throws {
        guard InTurnSync.isEnabled() else { return }
        let fails = SyncStreamSwitch()
        let f = await SyncStreamFixture<SyncStreamDropState>.makeDrop(encoder: SyncStreamFailingEncoder(fails: fails))
        fails.set(true)
        try await f.join()  // the firstSync fails entirely: the joiner is skipped
        await f.tick()      // the full view fails entirely: nothing reaches the client
        #expect(markers(try await f.stream()).isEmpty)
        fails.set(false)
        await f.tick()      // the full view is sent
        let seeds = markers(try await f.stream()).filter { $0.kind == .seed }
        #expect(seeds.count == 1)
        #expect(seeds.first?.rejoin == false)
        #expect(seeds.first?.observedTickId == 1)
        #expect(seeds.first?.viewHash != nil)
    }

    @Test("An opcode 107 plan that consumes an event without a keeper sequence has no events hash")
    func eventWithoutSequence() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: .messagepack)
        try await f.join()
        // Queued outside a turn: no keeper sequence.
        await f.adapter.sendEvent(
            AnyServerEvent(SyncStreamTestEvent(message: "outside")),
            to: .all
        )
        await f.tick()
        let tick = try #require(outputs(try await f.stream()).first { $0.turnKind == .tick })
        #expect(tick.eventsHash == nil)
        #expect(tick.encodeDropScopes == ["events"])
    }

    @Test("A freeze settle records a legacy-cycle output, located at its tick; stream indices increase across kinds")
    func legacyCycleAndStreamOrder() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await SyncStreamFixture<SyncStreamTestState>.make(encoding: .json)
        try await f.join()                 // seed
        await f.tick()                     // tick output, observed 0
        await f.tick()                     // tick output, observed 1
        let frozen = try await f.adapter.debugFreeze()  // legacy-cycle output (settle)
        _ = await f.adapter.debugResume(freezeToken: frozen.freezeToken)
        await f.adapter.onDisconnect(sessionID: f.session, clientID: f.client)  // clear
        let stream = try await f.stream()
        #expect(stream.map(\.streamIndex) == Array(0 ..< UInt64(stream.count)))
        let kinds: [String] = stream.map {
            switch $0 {
            case .output(let output): return output.turnKind.rawValue
            case .marker(let marker): return marker.kind.rawValue
            }
        }
        #expect(kinds == ["seed", "tick", "tick", "legacyCycle", "clear"])
        let legacy = try #require(outputs(stream).first { $0.turnKind == .legacyCycle })
        #expect(legacy.observedTickId == frozen.tickId)
        #expect(legacy.observedTickId == 1)
        let sequences = stream.map {
            switch $0 {
            case .output(let output): return output.sequence
            case .marker(let marker): return marker.sequence
            }
        }
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 <= $1 }, "sequences never decrease: \(sequences)")
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
