// Tests/SwiftStateTreeTransportTests/LandRouterJoinEventOverflowTests.swift
//
// A join whose held targeted events go over the bound (#69) fails with `eventOverflow`: the
// router answers JOIN_EVENT_OVERFLOW, unbinds the session, cleans up the adapter and the
// keeper's player, and closes the session.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct OverflowRouterTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

@Payload
struct OverflowRouterTestEvent: ServerEventPayload {
    let n: Int
}

/// Records what the transport sends to one session, and whether it was closed.
private actor OverflowConnection: WebSocketConnection {
    private(set) var messages: [Data] = []
    private(set) var closed = false

    func send(_ data: Data) async throws { messages.append(data) }
    func close() async throws { closed = true }
}

/// Polls an async condition for up to 5 s.
private func pollUntilOverflow(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite(
    "LandRouter: a join over the held-event bound (#69)",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: held events are on the in-turn path only")
)
struct LandRouterJoinEventOverflowTests {
    @Test("JOIN_EVENT_OVERFLOW is sent, the session is unbound and closed, and the keeper's player is removed")
    func overflowIsMappedAndCleanedUp() async throws {
        let definition = Land("overflow-test", using: OverflowRouterTestState.self) {
            ServerEvents { Register(OverflowRouterTestEvent.self) }
            Rules {
                OnJoin { (state: inout OverflowRouterTestState, ctx: LandContext) in
                    state.players[ctx.playerID] = "Joined"
                    for n in 0..<3 {
                        ctx.emitEvent(OverflowRouterTestEvent(n: n), to: .session(ctx.sessionID))
                    }
                }
                OnLeave { (state: inout OverflowRouterTestState, ctx: LandContext) in
                    state.players.removeValue(forKey: ctx.playerID)
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in OverflowRouterTestState() }
        )
        let manager = LandManager<OverflowRouterTestState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in OverflowRouterTestState() },
            transport: transport
        )
        let router = LandRouter<OverflowRouterTestState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)

        // The land exists before the join, with a bound of 2 held events: OnJoin sends 3.
        let landID = LandID(landType: "overflow-test", instanceId: "one")
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: OverflowRouterTestState(), metadata: [:])
        await container.transportAdapter.setHeldEventsLimitForTesting(count: 2, bytes: 1 << 20)

        let session = SessionID("s-overflow")
        let connection = OverflowConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1",
            landType: "overflow-test",
            landInstanceId: "one",
            playerID: "p1",
            deviceID: nil,
            metadata: nil
        ))
        await transport.handleIncomingMessage(sessionID: session, data: join)

        #expect(await pollUntilOverflow { await connection.closed }, "the session is closed")
        let codes = await connection.messages.compactMap { data -> String? in
            guard let message = try? JSONDecoder().decode(TransportMessage.self, from: data),
                  case .error(let payload) = message.payload else { return nil }
            return payload.code
        }
        #expect(codes == [ErrorCode.joinEventOverflow.rawValue])
        #expect(await router.getBoundLandID(for: session) == nil)
        #expect(await pollUntilOverflow { await container.keeper.currentState().players.isEmpty }, "the keeper's player is removed")
        #expect(await container.transportAdapter.isJoining(session) == false, "no joining record left")
        #expect(await container.transportAdapter.inTurnJoinFailures[.eventOverflow] == 1)
    }
}
