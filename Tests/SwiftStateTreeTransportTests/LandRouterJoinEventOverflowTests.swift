// Tests/SwiftStateTreeTransportTests/LandRouterJoinEventOverflowTests.swift
//
// A join whose held targeted events go over the bound (#69) fails with `eventOverflow`: the
// router answers JOIN_EVENT_OVERFLOW, unbinds the session, cleans up the adapter and the
// keeper's player, and closes the session.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

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
@Suite(
    "LandRouter: a join over the held-event bound (#69)"
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
        let registry = try LandTypeRegistry(
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
        let connection = RecordingConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1",
            landType: "overflow-test",
            landInstanceId: "one",
            playerID: "p1",
            deviceID: nil,
            metadata: nil
        ))
        // The router handles the join inline: once this returns, an admitted join's flip wait is
        // counted, or has already ended (the flip can finish first).
        await transport.handleIncomingMessage(sessionID: session, data: join)
        // The flip wait ends after the failure's handling: the error frame and the close handed
        // to the adapter's writer, and the adapter's cleanup, the keeper's leave included.
        #expect(await withinHangBound { await router.waitForNoPendingFlipForTesting() }, "the join's flip wait never ended")
        // The writer hands the close over after the error frame.
        #expect(await connection.waitUntilClosed(), "the session is closed")
        #expect(await connection.errorCodes == [ErrorCode.joinEventOverflow.rawValue])
        #expect(await router.getBoundLandID(for: session) == nil)
        #expect(await container.keeper.currentState().players.isEmpty, "the keeper's player is removed")
        #expect(await container.transportAdapter.isJoining(session) == false, "no joining record left")
        #expect(await container.transportAdapter.inTurnJoinFailures[.eventOverflow] == 1)
    }
}
