// Tests/SwiftStateTreeTransportTests/JoinPlayerIdentityTests.swift
//
// With authenticated info (a JWT), the token's identity wins (#209): a join that names no playerID,
// or the token's own, joins as the token's player; a join that names another player is rejected
// with JOIN_PLAYER_MISMATCH before any land is looked up or created. Without authenticated info,
// the join's playerID is used as before, except on a land that authenticates players: there a
// session without authenticated info is a guest, and a join that names a playerID is rejected with
// JOIN_PLAYER_MISMATCH (one that names none joins as a guest). Both join paths are covered: the
// router and the legacy adapter join.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// Records what the transport sends to one session.
private actor IdentityReplyConnection: WebSocketConnection {
    private(set) var messages: [Data] = []

    func send(_ data: Data) async throws {
        messages.append(data)
    }

    func close() async throws {}
}

private func errorCode(_ data: Data) -> String? {
    guard let message = try? JSONDecoder().decode(TransportMessage.self, from: data),
          case .error(let payload) = message.payload else { return nil }
    return payload.code
}

private func routerJoin(playerID: String?) -> Data {
    try! JSONEncoder().encode(TransportMessage.join(
        requestID: "join-1",
        landType: "basic-test",
        landInstanceId: "identity",
        playerID: playerID,
        deviceID: nil,
        metadata: StateUpdateFeature.joinMetadata
    ))
}

private let token = AuthenticatedInfo(playerID: "p1")

@Suite("Join identity with JWT (#209)")
struct JoinPlayerIdentityTests {
    // MARK: Resolution

    @Test("joinIdentityRejection: a token for another player, or no token on a land that authenticates players")
    func rejectionRule() {
        typealias A = TransportAdapter<RouterTestState>
        for authenticates in [true, false] {
            #expect(A.joinIdentityRejection(requestedPlayerID: "p2", authInfo: token, authenticatesPlayers: authenticates) == .tokenMismatch(tokenPlayerID: "p1"))
            #expect(A.joinIdentityRejection(requestedPlayerID: "p1", authInfo: token, authenticatesPlayers: authenticates) == nil)
            #expect(A.joinIdentityRejection(requestedPlayerID: nil, authInfo: token, authenticatesPlayers: authenticates) == nil)
            #expect(A.joinIdentityRejection(requestedPlayerID: nil, authInfo: nil, authenticatesPlayers: authenticates) == nil)
        }
        #expect(A.joinIdentityRejection(requestedPlayerID: "p2", authInfo: nil, authenticatesPlayers: true) == .unauthenticated)
        #expect(A.joinIdentityRejection(requestedPlayerID: "p2", authInfo: nil, authenticatesPlayers: false) == nil)
    }

    @Test("preparePlayerSession: the token's playerID wins even if a caller skips the check")
    func tokenWinsInResolution() async throws {
        let (_, router, manager) = try await LandRouterTests().setupRouter()
        _ = router
        let landID = LandID(landType: "basic-test", instanceId: "resolution")
        let definition = Land("basic-test", using: RouterTestState.self) { Rules {} }
        let container = try await manager.getOrCreateLand(landID: landID, definition: definition, initialState: RouterTestState(), metadata: [:])
        let adapter = container.transportAdapter
        let session = SessionID("s-resolution")
        let client = ClientID("c-resolution")

        let withToken = await adapter.preparePlayerSession(sessionID: session, clientID: client, requestedPlayerID: "p2", deviceID: nil, metadata: nil, authInfo: token)
        #expect(withToken.playerID == "p1")
        #expect(withToken.isGuest == false)
        let tokenOnly = await adapter.preparePlayerSession(sessionID: session, clientID: client, requestedPlayerID: nil, deviceID: nil, metadata: nil, authInfo: token)
        #expect(tokenOnly.playerID == "p1")
        #expect(tokenOnly.isGuest == false)
        let noToken = await adapter.preparePlayerSession(sessionID: session, clientID: client, requestedPlayerID: "p2", deviceID: nil, metadata: nil, authInfo: nil)
        #expect(noToken.playerID == "p2")
        #expect(noToken.isGuest == false)
    }

    // MARK: Router path

    @Test("Router: a JWT for p1 joining as p2 is rejected with JOIN_PLAYER_MISMATCH, and no land is created")
    func routerRejectsMismatch() async throws {
        let (transport, router, manager) = try await LandRouterTests().setupRouter()
        let session = SessionID("s-mismatch")
        let connection = IdentityReplyConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: token)
        await transport.handleIncomingMessage(sessionID: session, data: routerJoin(playerID: "p2"))

        #expect(await pollUntil { await !connection.messages.isEmpty })
        let reply = try #require(await connection.messages.first)
        #expect(errorCode(reply) == ErrorCode.joinPlayerMismatch.rawValue)
        #expect(await router.getBoundLandID(for: session) == nil)
        #expect(await manager.listLands().isEmpty, "rejected before any land is created")
    }

    @Test("Router: a JWT for p1 joins as p1 with playerID p1 or none", arguments: ["p1", nil] as [String?])
    func routerJoinsAsTokenPlayer(requested: String?) async throws {
        let (transport, router, manager) = try await LandRouterTests().setupRouter()
        let session = SessionID("s-token")
        await transport.handleConnection(sessionID: session, connection: IdentityReplyConnection(), authInfo: token)
        await transport.handleIncomingMessage(sessionID: session, data: routerJoin(playerID: requested))

        let landID = try #require(await router.getBoundLandID(for: session))
        let container = try #require(await manager.getLand(landID: landID))
        let players = await container.keeper.currentState().players
        #expect(players == [PlayerID("p1"): "Joined"], "players: \(players)")
    }

    @Test("Router, land that authenticates players: without a JWT, a join as p2 is rejected; one with no playerID joins as a guest")
    func routerAuthenticatingLandRejectsTokenless() async throws {
        let (transport, router, manager) = try await authenticatingRouter()
        let rejected = SessionID("s-tokenless")
        let connection = IdentityReplyConnection()
        await transport.handleConnection(sessionID: rejected, connection: connection, authInfo: nil)
        await transport.handleIncomingMessage(sessionID: rejected, data: routerJoin(playerID: "p2"))
        #expect(await pollUntil { await !connection.messages.isEmpty })
        let reply = try #require(await connection.messages.first)
        #expect(errorCode(reply) == ErrorCode.joinPlayerMismatch.rawValue)
        #expect(await router.getBoundLandID(for: rejected) == nil)
        #expect(await manager.listLands().isEmpty, "rejected before any land is created")

        let guest = SessionID("s-guest")
        await transport.handleConnection(sessionID: guest, connection: IdentityReplyConnection(), authInfo: nil)
        await transport.handleIncomingMessage(sessionID: guest, data: routerJoin(playerID: nil))
        let landID = try #require(await router.getBoundLandID(for: guest))
        let container = try #require(await manager.getLand(landID: landID))
        #expect(await container.keeper.currentState().players == [PlayerID(guest.rawValue): "Joined"], "the default guest session's playerID")
    }

    @Test("Router: without a JWT, a join as p2 joins as p2")
    func routerWithoutTokenUsesRequested() async throws {
        let (transport, router, manager) = try await LandRouterTests().setupRouter()
        let session = SessionID("s-guestless")
        await transport.handleConnection(sessionID: session, connection: IdentityReplyConnection(), authInfo: nil)
        await transport.handleIncomingMessage(sessionID: session, data: routerJoin(playerID: "p2"))

        let landID = try #require(await router.getBoundLandID(for: session))
        let container = try #require(await manager.getLand(landID: landID))
        #expect(await container.keeper.currentState().players == [PlayerID("p2"): "Joined"])
    }

    // MARK: Legacy adapter path

    private func legacyAdapter(authenticatesPlayers: Bool = false) async -> (TransportAdapter<RouterTestState>, LandKeeper<RouterTestState>, WebSocketTransport) {
        let definition = Land("identity-legacy", using: RouterTestState.self) {
            Rules {
                OnJoin { (state: inout RouterTestState, ctx: LandContext) in
                    state.players[ctx.playerID] = "Joined"
                }
            }
        }
        let transport = WebSocketTransport()
        let keeper = LandKeeper<RouterTestState>(definition: definition, initialState: RouterTestState())
        let adapter = TransportAdapter<RouterTestState>(keeper: keeper, transport: transport, landID: "identity-legacy", authenticatesPlayers: authenticatesPlayers, enableLegacyJoin: true)
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        return (adapter, keeper, transport)
    }

    private func legacyJoin(playerID: String?) -> Data {
        try! JSONEncoder().encode(TransportMessage.join(requestID: "join-1", landID: "identity-legacy", playerID: playerID, deviceID: nil, metadata: StateUpdateFeature.joinMetadata))
    }

    @Test("Legacy join: a JWT for p1 joining as p2 is rejected with JOIN_PLAYER_MISMATCH")
    func legacyRejectsMismatch() async throws {
        let (adapter, keeper, transport) = await legacyAdapter()
        let session = SessionID("s-legacy-mismatch")
        let connection = IdentityReplyConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: token)
        await transport.handleIncomingMessage(sessionID: session, data: legacyJoin(playerID: "p2"))

        #expect(await pollUntil { await !connection.messages.isEmpty })
        let reply = try #require(await connection.messages.first)
        #expect(errorCode(reply) == ErrorCode.joinPlayerMismatch.rawValue)
        #expect(await adapter.isJoined(sessionID: session) == false)
        #expect(await keeper.currentState().players.isEmpty)
    }

    @Test("Legacy join, land that authenticates players: without a JWT, a join as p2 is rejected")
    func legacyAuthenticatingLandRejectsTokenless() async throws {
        let (adapter, keeper, transport) = await legacyAdapter(authenticatesPlayers: true)
        let session = SessionID("s-legacy-tokenless")
        let connection = IdentityReplyConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        await transport.handleIncomingMessage(sessionID: session, data: legacyJoin(playerID: "p2"))
        #expect(await pollUntil { await !connection.messages.isEmpty })
        let reply = try #require(await connection.messages.first)
        #expect(errorCode(reply) == ErrorCode.joinPlayerMismatch.rawValue)
        #expect(await adapter.isJoined(sessionID: session) == false)
        #expect(await keeper.currentState().players.isEmpty)
    }

    @Test("Legacy join: a JWT for p1 joins as p1 with playerID p1 or none; no JWT joins as p2", arguments: [
        ("p1", true, "p1"), (nil, true, "p1"), ("p2", false, "p2"),
    ] as [(String?, Bool, String)])
    func legacyResolution(requested: String?, withToken: Bool, expected: String) async throws {
        let (adapter, keeper, transport) = await legacyAdapter()
        let session = SessionID("s-legacy")
        await transport.handleConnection(sessionID: session, connection: IdentityReplyConnection(), authInfo: withToken ? token : nil)
        await transport.handleIncomingMessage(sessionID: session, data: legacyJoin(playerID: requested))

        #expect(await pollUntil { await adapter.isJoined(sessionID: session) })
        #expect(await keeper.currentState().players == [PlayerID(expected): "Joined"])
    }
}

/// A router like `LandRouterTests.setupRouter`, for a land type that authenticates players.
private func authenticatingRouter() async throws -> (WebSocketTransport, LandRouter<RouterTestState>, LandManager<RouterTestState>) {
    let transport = WebSocketTransport()
    let definition = Land("basic-test", using: RouterTestState.self) {
        Rules {
            OnJoin { (state: inout RouterTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    let registry = try LandTypeRegistry<RouterTestState>(
        landFactory: { _, _ in definition },
        initialStateFactory: { _, _ in RouterTestState() }
    )
    let manager = LandManager<RouterTestState>(
        landFactory: { _ in definition },
        initialStateFactory: { _ in RouterTestState() },
        transport: transport,
        authenticatesPlayers: true
    )
    let router = LandRouter<RouterTestState>(
        landManager: manager,
        landTypeRegistry: registry,
        transport: transport,
        authenticatesPlayers: true,
        allowAutoCreateOnJoin: true
    )
    await transport.setDelegate(router)
    return (transport, router, manager)
}

