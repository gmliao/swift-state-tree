// Tests/SwiftStateTreeTransportTests/LandRouterShutdownTests.swift
//
// The router's part in a server shutdown (#351): `stopAccepting` fences joins (to existing
// lands too) and new connections, and `closeSessionsForShutdown` closes every session with 1001,
// each joined one after its leave ran. Joins are held at the router's hold points, never timed.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct RouterShutdownState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [String] = []
    @Sync(.broadcast)
    var leaves: [String] = []
}

/// Records each frame and the close code.
private actor RouterShutdownConnection: WebSocketConnection {
    private(set) var frames: [Data] = []
    private(set) var closeCode: UInt16?

    func send(_ data: Data) async throws { frames.append(data) }
    func close() async throws { closeCode = 1000 }
    func close(with close: SessionClose) async throws { closeCode = close.code }

    var errorCodes: [String] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
            .compactMap { if case .error(let payload) = $0.payload { return payload.code } else { return nil } }
    }
}

/// A router, its transport and one existing land.
private struct RouterShutdownHarness {
    let transport: WebSocketTransport
    let router: LandRouter<RouterShutdownState>
    let manager: LandManager<RouterShutdownState>
    let container: LandContainer<RouterShutdownState>

    var keeper: LandKeeper<RouterShutdownState> { container.keeper }

    static func make() async throws -> RouterShutdownHarness {
        let definition = Land("router-shutdown", using: RouterShutdownState.self) {
            Rules {
                CanJoin { (_: RouterShutdownState, session: PlayerSession, _: LandContext) in
                    .allow(playerID: PlayerID(session.playerID))
                }
                OnJoin { (state: inout RouterShutdownState, ctx: LandContext) in
                    state.players.append(ctx.playerID.rawValue)
                }
                OnLeave { (state: inout RouterShutdownState, ctx: LandContext) in
                    state.players.removeAll { $0 == ctx.playerID.rawValue }
                    state.leaves.append(ctx.playerID.rawValue)
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in RouterShutdownState() }
        )
        let manager = LandManager<RouterShutdownState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in RouterShutdownState() },
            transport: transport
        )
        let router = LandRouter<RouterShutdownState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)
        let landID = LandID(landType: "router-shutdown", instanceId: "one")
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: RouterShutdownState(), metadata: [:])
        return RouterShutdownHarness(transport: transport, router: router, manager: manager, container: container)
    }

    func connect(_ session: SessionID) async -> RouterShutdownConnection {
        let connection = RouterShutdownConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return connection
    }

    func startJoin(_ session: SessionID, player: String) throws -> Task<Void, Never> {
        let frame = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-\(player)", landType: "router-shutdown", landInstanceId: "one",
            playerID: player, deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        ))
        let router = self.router
        return Task { await router.onMessage(frame, from: session) }
    }

    func join(_ player: String) async throws -> RouterShutdownConnection {
        let session = SessionID("s-\(player)")
        let connection = await connect(session)
        _ = try startJoin(session, player: player)
        #expect(await pollUntilAsync { await keeper.currentState().players.contains(player) }, "\(player) joined")
        return connection
    }
}

private func pollUntilAsync(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite("LandRouter shutdown (#351)", .timeLimit(.minutes(1)))
struct LandRouterShutdownTests {
    @Test("a join to an existing land that is past its lookup when accepting stops is refused, with no binding")
    func joinToExistingLandFenced() async throws {
        let h = try await RouterShutdownHarness.make()
        let session = SessionID("s-late")
        let connection = await h.connect(session)
        let gate = TestGate()
        let registry = HoldRegistry<LandRouterHoldPoint>().on(.afterLand, arrival: 1) { await gate.arrive() }
        await h.router.installHolds(registry.hook)
        let join = try h.startJoin(session, player: "late")
        #expect(await gate.waitForArrivals(1), "the join found the existing land and is held before binding")

        await h.router.stopAccepting()
        gate.open()
        await join.value

        #expect(await connection.errorCodes == [ErrorCode.joinDenied.rawValue])
        #expect(await h.keeper.currentState().players.isEmpty)
        // Not bound: a shutdown's session step has no leave to run for it.
        let progress = ShutdownLeaveProgress()
        await h.router.closeSessionsForShutdown(progress: progress)
        #expect(progress.snapshot.leaves == 0)
        #expect(progress.snapshot.sessionsClosed == 1)
        #expect(await connection.closeCode == 1001)
    }

    @Test("a connection that arrives after accepting stopped is closed at once with 1001")
    func connectionAfterStopClosed() async throws {
        let h = try await RouterShutdownHarness.make()
        await h.router.stopAccepting()
        let connection = await h.connect(SessionID("s-new"))
        #expect(await connection.closeCode == 1001)
        let progress = ShutdownLeaveProgress()
        await h.router.closeSessionsForShutdown(progress: progress)
        #expect(progress.snapshot.sessions == 0, "nothing was recorded for it")
    }

    @Test("closeSessionsForShutdown returns after each joined session's leave ran, and closes joined and unjoined sessions with 1001")
    func closeSessionsAwaitsLeaves() async throws {
        let h = try await RouterShutdownHarness.make()
        let c1 = try await h.join("p1")
        let c2 = try await h.join("p2")
        let unjoined = await h.connect(SessionID("s-idle"))
        await h.router.stopAccepting()

        let progress = ShutdownLeaveProgress()
        await h.router.closeSessionsForShutdown(progress: progress)

        // Returned: the leaves already ran, OnLeave included.
        let state = await h.keeper.currentState()
        #expect(Set(state.leaves) == ["p1", "p2"])
        #expect(state.players.isEmpty)
        #expect(progress.snapshot == {
            var expected = ShutdownLeaveProgress.Snapshot()
            expected.leaves = 2
            expected.leavesFinished = 2
            expected.sessions = 3
            expected.sessionsClosed = 3
            return expected
        }())
        #expect(await c1.closeCode == 1001)
        #expect(await c2.closeCode == 1001)
        #expect(await unjoined.closeCode == 1001)
    }
}
