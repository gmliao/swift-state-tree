// #521 PR 1b-2a (D10): whether an event can merge into the opcode 107 frame is decided once at
// init. The tests count the two encodes per event: the merged body
// (`EncodingPipeline.encodeServerEventBody`) and the event's own frame
// (`EventSendingPipeline.prepareImmediateSend`).
//
// - Hybrid (`json` or `opcodeJsonArray` messages, `opcodeMessagePack` state updates): (0, 1), sent
//   alone, with no body attempt.
// - MessagePack, an event that merges: (1, 0), queued, and in the next 107 frame.
// - MessagePack, a payload whose positional form fails: (1, 0), lost, with no second encode.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

actor HybridCountingTestTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [Data] = []
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append(message) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, _) in updates { frames.append(data) }
    }
}

/// The hybrid golden land, but each tick emits an untyped dictionary under the registered event's
/// name (`emitAnyServerEventForTesting`): with MessagePack messages and payload compression on,
/// its positional form fails.
func makeUntypedEmitLand() -> LandDefinition<HybridGoldenState> {
    Land("hybrid-event-frames", using: HybridGoldenState.self) {
        ServerEvents { Register(HybridGoldenEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                ctx.emitAnyServerEventForTesting(
                    AnyServerEvent(
                        type: AnyServerEvent(HybridGoldenEvent(message: "", n: 0)).type,
                        payload: AnyCodable(["message": AnyCodable("untyped"), "n": AnyCodable(state.ticks)])
                    ),
                    to: .all
                )
                ctx.requestSyncNow()
            }
        }
    }
}

@Suite("Hybrid events decided at init: the encodes per event (#521 PR 1b-2a, D10)", .serialized)
struct HybridEventsAtInitTests {
    struct Fixture {
        let keeper: LandKeeper<HybridGoldenState>
        let adapter: TransportAdapter<HybridGoldenState>
        let transport: HybridCountingTestTransport
        let counts: EventEncodeCountsForTesting
        /// The counts after the join, before the test's events.
        let before: (body: Int, ownFrame: Int)

        /// The encodes since the join.
        var since: (body: Int, ownFrame: Int) {
            let now = counts.counts
            return (now.body - before.body, now.ownFrame - before.ownFrame)
        }
    }

    /// The hybrid golden land (`HybridEventFrameGoldenTests`), one player joined, counting from
    /// after the join.
    static func make(
        _ config: TransportEncodingConfig,
        definition: LandDefinition<HybridGoldenState> = makeHybridGoldenLand()
    ) async throws -> Fixture {
        let keeper = LandKeeper<HybridGoldenState>(
            definition: definition,
            initialState: HybridGoldenState(),
            autoStartLoops: false
        )
        let transport = HybridCountingTestTransport()
        let counts = EventEncodeCountsForTesting()
        let adapter = TransportAdapter<HybridGoldenState>(
            keeper: keeper,
            transport: transport,
            landID: "hybrid-event-frames",
            encodingConfig: config,
            pathHashes: HybridEventFrameGoldenTests.schema.pathHashes,
            eventHashes: HybridEventFrameGoldenTests.schema.eventHashes,
            suppressMissingPathHashesWarning: true,
            joinsThroughRouter: false,
            eventEncodeCountsForTesting: counts
        )
        await transport.setDelegate(adapter)
        await keeper.awaitInitialization()
        await keeper.setTransport(adapter)
        let (session, client) = (SessionID("s1"), ClientID("c1"))
        await adapter.onConnect(sessionID: session, clientID: client)
        let decision = try await keeper.join(
            session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, services: LandServices()
        )
        guard case .allow(let player) = decision else { throw CancellationError() }
        await adapter.registerSession(sessionID: session, clientID: client, playerID: player, authInfo: nil)
        _ = await adapter.allocatePlayerSlot(accountKey: player.rawValue, for: player)
        await adapter.syncStateForNewPlayer(playerID: player, sessionID: session)
        await adapter.waitForOutboundIdleForTesting()
        return Fixture(keeper: keeper, adapter: adapter, transport: transport, counts: counts, before: counts.counts)
    }

    static func typed(_ message: String) -> AnyServerEvent {
        AnyServerEvent(HybridGoldenEvent(message: message, n: 1))
    }

    @Test(
        "Hybrid: each event is encoded once, as its own frame, with no merged body attempt",
        arguments: [TransportEncoding.json, .opcodeJsonArray]
    )
    func hybridEncodesOnce(message: TransportEncoding) async throws {
        let f = try await Self.make(TransportEncodingConfig(message: message, stateUpdate: .opcodeMessagePack))
        let targets: [SwiftStateTree.EventTarget] = [.all, .players([]), .player(PlayerID("p1"))]
        for (n, target) in targets.enumerated() {
            let outcome = await f.adapter.enqueueEventSynchronously(Self.typed("e\(n)"), to: target)
            #expect(outcome == .sentAlone, "\(message) \(target)")
            #expect(f.since == (0, n + 1), "\(message) \(target)")
        }
    }

    @Test("MessagePack: an event that merges encodes its body once and is in the next merged frame")
    func messagePackMerges() async throws {
        let f = try await Self.make(.messagepack)
        let outcome = await f.adapter.enqueueEventSynchronously(Self.typed("merged-event"), to: .all)
        #expect(outcome == .queued)
        #expect(f.since == (1, 0))
        let before = await f.transport.frames.count
        await f.keeper.stepTickOnce()
        await f.adapter.waitForOutboundIdleForTesting()
        let sent = await f.transport.frames.dropFirst(before)
        let merged = sent.filter { $0.range(of: Data("merged-event".utf8)) != nil }
        #expect(merged.count == 1, "one frame carries the event")
        // An opcode 107 frame is a MessagePack array whose first element is 107 (0x6b).
        #expect(merged.first.map { $0.count > 1 && $0[$0.startIndex + 1] == 0x6b } == true, "it is the merged frame")
    }

    @Test("MessagePack: a payload whose body doesn't encode is lost after one encode, with no own frame")
    func messagePackBodyFailureIsLost() async throws {
        let f = try await Self.make(.messagepack)
        // An untyped dictionary: with payload compression on, its positional form fails.
        let untyped = AnyServerEvent(type: Self.typed("").type, payload: AnyCodable(["message": AnyCodable("x"), "n": AnyCodable(1)]))
        let before = await f.transport.frames.count
        let outcome = await f.adapter.enqueueEventSynchronously(untyped, to: .all)
        #expect(outcome == .lost)
        #expect(f.since == (1, 0))
        #expect(await f.transport.frames.count == before)
    }

    @Test("MessagePack, from a land's turn: a payload whose body doesn't encode is lost after one encode and ends the land")
    func messagePackBodyFailureFromATurnEndsTheLand() async throws {
        let f = try await Self.make(.messagepack, definition: makeUntypedEmitLand())
        let before = await f.transport.frames.count
        await f.keeper.stepTickOnce()
        #expect(f.since == (1, 0), "one body encode, no own frame")
        // In-turn sync flushes the turn's events in its sync phase and ends the land in the same
        // turn.
        #expect(f.adapter.outputGate.failure?.position.stage == .syncPhase)
        try #require(await f.keeper.waitForFailureForTesting(), "the land failed")
        #expect(f.keeper.failure?.kind == .eventEncode)
        #expect(f.adapter.outputGate.isClosed)
        await f.adapter.waitForOutboundIdleForTesting()
        #expect(await f.transport.frames.count == before, "the failing turn sends nothing")
    }
}
