// Tests/SwiftStateTreeTransportTests/EventFramePackBytesTests.swift
//
// The bytes of the event frames (opcode 103) the adapter packs for targeted events, in opcode
// MessagePack, the only encoding that sends them (state updates and broadcast events merge into
// opcode 107; targeted events go as their own frames). Written before #554 moves the pack out of
// the adapter: no benchmark cell reaches it, so these bytes are what pins the move.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct EventFramePinState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0
}

@Payload
struct EventFramePinEvent: ServerEventPayload {
    let note: String
    let count: Int
}

/// Records every frame sent to a session, in send order.
private actor PinFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append((message, target)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    /// The event frames (opcode 103) `sessionID` received, as hex, in order.
    func eventFrames(for sessionID: SessionID) -> [String] {
        frames.compactMap { frame in
            guard case .session(let s) = frame.target, s == sessionID,
                  case .array(let array)? = try? unpack(frame.data),
                  case .int(let opcode)? = array.first, opcode == Int64(MessageKindOpcode.event.rawValue)
            else { return nil }
            return frame.data.map { String(format: "%02x", $0) }.joined()
        }
    }
}

private struct PinFixture {
    let keeper: LandKeeper<EventFramePinState>
    let adapter: TransportAdapter<EventFramePinState>
    let sent: PinFrames
}

/// OnJoin sends the joiner one `.session` event, held until its firstSync.
private func makePinFixture() async -> PinFixture {
    let definition = Land("event-frame-pin", using: EventFramePinState.self) {
        ServerEvents { Register(EventFramePinEvent.self) }
        Rules {
            OnJoin { (state: inout EventFramePinState, ctx: LandContext) in
                state.joins += 1
                ctx.emitEvent(EventFramePinEvent(note: "held", count: 7), to: .session(ctx.sessionID))
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout EventFramePinState, _: LandContext) in }
        }
    }
    let sent = PinFrames()
    let keeper = LandKeeper(definition: definition, initialState: EventFramePinState(), autoStartLoops: true)
    let adapter = TransportAdapter<EventFramePinState>(
        keeper: keeper,
        transport: sent,
        landID: "event-frame-pin",
        encodingConfig: .messagepack,
        inTurnSync: true
    )
    await sent.setDelegate(adapter)
    await keeper.setTransport(adapter)
    return PinFixture(keeper: keeper, adapter: adapter, sent: sent)
}

/// Joins `player` on `session` through the in-turn path. `admitJoin` returns once the join is
/// registered and waits for its flip; one tick step flips it, and `awaitJoined` waits for that.
private func joinPin(_ fixture: PinFixture, session: SessionID, player: String) async throws {
    let client = ClientID("c-\(session.rawValue)")
    await fixture.adapter.onConnect(sessionID: session, clientID: client)
    let admitted = try await fixture.adapter.admitJoin(
        playerSession: PlayerSession(playerID: player, deviceID: "dev", metadata: [:]),
        clientID: client,
        sessionID: session,
        authInfo: nil,
        joinResponse: { _, _ in Data("{}".utf8) }
    )
    #expect(admitted?.completedInTurn == true)
    await fixture.keeper.stepTickOnce()
    try await fixture.adapter.awaitJoined(sessionID: session)
    await fixture.adapter.waitForOutboundIdleForTesting()
}

@Suite(
    "Event frame bytes for targeted events, opcode MessagePack (#554)",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: the joiner's held events are on the in-turn path only")
)
struct EventFramePackBytesTests {
    /// The held event OnJoin sent the joiner, packed at its flip.
    static let heldFrame = "946701ad4576656e744672616d6550696e9207a468656c64"
    /// A `.player` event to a joined player, packed by the full sync plan.
    static let targetedFrame = "946701ad4576656e744672616d6550696e92fda87461726765746564"

    @Test("A joiner's held event and a joined player's targeted event pack to the same bytes as before the move")
    func bytes() async throws {
        let fixture = await makePinFixture()
        let s0 = SessionID("s0")
        try await joinPin(fixture, session: s0, player: "p0")
        let held = await fixture.sent.eventFrames(for: s0)
        #expect(held == [Self.heldFrame], "\(held)")

        await fixture.adapter.sendEvent(
            AnyServerEvent(EventFramePinEvent(note: "targeted", count: -3)),
            to: .player(PlayerID("p0"))
        )
        await fixture.adapter.syncNow()
        await fixture.adapter.waitForOutboundIdleForTesting()
        let all = await fixture.sent.eventFrames(for: s0)
        #expect(all == [Self.heldFrame, Self.targetedFrame], "\(all)")
    }
}
