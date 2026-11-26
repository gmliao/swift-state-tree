// Tests/SwiftStateTreeTests/KeeperPlayerServicesTests.swift
//
// A player's services live beside the keeper's model, in `playerServices`, keyed by the player
// entry's generation (#700 K1b-4). Every insert and removal of a player entry writes the table in
// the same segment; a context reads the current entry's services; the OnLeave resolvers get the
// outgoing entry's.

import Foundation
import Synchronization
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport

/// One service type, registered with different values at different scopes.
struct PlayerServicesTag: Sendable, Equatable {
    let value: String
}

@StateNodeBuilder
struct PlayerServicesState: StateNodeProtocol {
    /// The tag each handler saw, as `"<handler>:<tag>"`.
    @Sync(.broadcast)
    var seen: [String] = []

    init() {}
}

@Payload
struct PlayerServicesAction: ActionPayload {
    typealias Response = PlayerServicesAck
    let n: Int
}

@Payload
struct PlayerServicesAck: ResponsePayload {
    let ok: Bool
}

@PlainData
struct PlayerServicesSeen: ResolverOutput, Equatable {
    let tag: String
}

private func tag(_ ctx: LandContext) -> String {
    ctx.services.get(PlayerServicesTag.self)?.value ?? "none"
}

private func services(_ value: String) -> LandServices {
    var services = LandServices()
    services.register(PlayerServicesTag(value: value), as: PlayerServicesTag.self)
    return services
}

/// What the OnLeave resolvers saw, in order.
enum PlayerServicesLeaveLog {
    private static let seen = Mutex<[String: [String]]>([:])
    static func add(_ land: String, _ tag: String) { seen.withLock { $0[land, default: []].append(tag) } }
    static func tags(_ land: String) -> [String] { seen.withLock { $0[land] ?? [] } }
}

/// Records the services' tag an OnLeave resolver sees, by land.
struct PlayerServicesLeaveResolver: ContextResolver {
    typealias Output = PlayerServicesSeen
    static func resolve(ctx: ResolverContext) async throws -> PlayerServicesSeen {
        let seen = ctx.services.get(PlayerServicesTag.self)?.value ?? "none"
        PlayerServicesLeaveLog.add(ctx.landID, seen)
        return PlayerServicesSeen(tag: seen)
    }
}

struct PlayerServicesJoinRefused: Error {}

/// An OnJoin resolver that fails for the entry tagged `"fail"`, after waiting at its land's gate
/// when one is set; any other entry passes.
struct PlayerServicesJoinResolver: ContextResolver {
    typealias Output = PlayerServicesSeen
    static let gates = Mutex<[String: TestGate]>([:])
    static func resolve(ctx: ResolverContext) async throws -> PlayerServicesSeen {
        let seen = ctx.services.get(PlayerServicesTag.self)?.value ?? "none"
        guard seen == "fail" else { return PlayerServicesSeen(tag: seen) }
        if let gate = gates.withLock({ $0[ctx.landID] }) { await gate.arrive() }
        throw PlayerServicesJoinRefused()
    }
}

private let player = PlayerID("p1")
private let client = ClientID("c1")
private let session = SessionID("s1")

private func playerSession() -> PlayerSession {
    PlayerSession(playerID: player.rawValue, deviceID: nil, metadata: [:])
}

private func action() -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: PlayerServicesAction.self), payload: AnyCodable(PlayerServicesAction(n: 1)))
}

private func makeLand(_ id: String) -> LandDefinition<PlayerServicesState> {
    Land(id, using: PlayerServicesState.self) {
        Rules {
            OnJoin(resolvers: PlayerServicesJoinResolver.self) { state, _, ctx in
                state.seen.append("join:\(tag(ctx))")
            }
            OnLeave(resolvers: PlayerServicesLeaveResolver.self) { state, _, ctx in
                state.seen.append("leave:\(tag(ctx))")
            }
            HandleAction(PlayerServicesAction.self) { state, _, ctx in
                state.seen.append("action:\(tag(ctx))")
                return PlayerServicesAck(ok: true)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

private func makeKeeper(_ id: String, landServices: LandServices = LandServices()) async -> LandKeeper<PlayerServicesState> {
    let keeper = LandKeeper(definition: makeLand(id), initialState: PlayerServicesState(), services: landServices, autoStartLoops: false, landID: id)
    await keeper.awaitInitialization()
    return keeper
}

/// The table holds exactly the players' entries, each at its entry's generation.
private func expectAligned(_ keeper: LandKeeper<PlayerServicesState>, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    let generations = await keeper.playerServiceGenerationsForTesting()
    #expect(generations.services == generations.players, "\(step)", sourceLocation: sourceLocation)
}

@Suite("A player's services beside the keeper's model (#700 K1b-4)")
struct KeeperPlayerServicesTests {
    @Test("After a join, the player's action sees the player's services")
    func joinThenAction() async throws {
        let keeper = await makeKeeper("ps-join-action")
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("player"))
        await expectAligned(keeper, "joined")
        _ = try await keeper.handleActionEnvelope(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().seen == ["join:player", "action:player"])
    }

    @Test("A player's services win over the land's for the same type")
    func playerScopeWins() async throws {
        let keeper = await makeKeeper("ps-precedence", landServices: services("land"))
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("player"))
        _ = try await keeper.handleActionEnvelope(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().seen == ["join:player", "action:player"])
    }

    @Test("The OnLeave resolvers see the outgoing entry's services; the table drops them")
    func leaveResolverSeesOutgoingServices() async throws {
        let land = "ps-leave"
        let keeper = await makeKeeper(land)
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("player"))
        try await keeper.leave(playerID: player, clientID: client, sessionID: session)
        await expectAligned(keeper, "left")
        #expect(await keeper.playerServiceGenerationsForTesting().services.isEmpty)
        #expect(PlayerServicesLeaveLog.tags(land) == ["player"])
    }

    @Test("The resolvers see the outgoing services; the queued OnLeave sees the entry current when it applies")
    func resolverSnapshotAndQueuedLookup() async throws {
        let land = "ps-leave-rejoin"
        let keeper = await makeKeeper(land)
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("first"))
        await keeper.stepTickOnce()
        try await keeper.leave(playerID: player, clientID: client, sessionID: session)
        // Rejoined before the queued OnLeave applies (at the next tick).
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("second"))
        await expectAligned(keeper, "rejoined")
        await keeper.stepTickOnce()
        #expect(PlayerServicesLeaveLog.tags(land) == ["first"])
        // The queued inputs apply in intake order, each with the entry current at the tick.
        #expect(await keeper.currentState().seen == ["join:first", "leave:second", "join:second"])
    }

    @Test("A failed join's rollback removes its services with its entry")
    func failedJoinRollsBackTheTable() async throws {
        let keeper = await makeKeeper("ps-rollback")
        await #expect(throws: (any Error).self) {
            try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("fail"))
        }
        // Right after the rollback: nothing else has cleared the table.
        let generations = await keeper.playerServiceGenerationsForTesting()
        #expect(generations.players.isEmpty)
        #expect(generations.services == generations.players)
    }

    @Test("A newer entry keeps its services when an older join rolls back")
    func newerEntrySurvivesOlderRollback() async throws {
        let land = "ps-newer"
        let gate = TestGate()
        PlayerServicesJoinResolver.gates.withLock { $0[land] = gate }
        defer { PlayerServicesJoinResolver.gates.withLock { $0[land] = nil }; gate.open() }
        let keeper = await makeKeeper(land)
        let older = Task {
            try await keeper.join(playerID: player, clientID: ClientID("c-old"), sessionID: SessionID("s-old"), services: services("fail"))
        }
        #expect(await gate.waitForArrivals(1), "the older join's resolver is waiting")
        // The newer join kicks the older entry and inserts its own.
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("newer"))
        gate.open()
        await #expect(throws: (any Error).self) { try await older.value }
        await expectAligned(keeper, "after the older rollback")
        #expect(await keeper.playerServiceGenerationsForTesting().services[player] != nil, "the newer entry's services stay")
        _ = try await keeper.handleActionEnvelope(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().seen.last == "action:newer")
    }

    // The production join (`join(session:…)`, through `joinReportingAdmission`), the path the
    // adapter's join takes; these tests call it directly (no transport admission).

    @Test("A session join's insert writes the table; the player's action sees its services")
    func sessionJoinThenAction() async throws {
        let keeper = await makeKeeper("ps-session-join")
        _ = try await keeper.join(session: playerSession(), clientID: client, sessionID: session, services: services("player"))
        await expectAligned(keeper, "joined")
        _ = try await keeper.handleActionEnvelope(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().seen == ["join:player", "action:player"])
    }

    @Test("A session join that kicks the player's older session (#862): the newer entry's services replace the older's")
    func sessionKickAndRejoin() async throws {
        let land = "ps-session-kick"
        let keeper = await makeKeeper(land)
        _ = try await keeper.join(session: playerSession(), clientID: ClientID("c-old"), sessionID: SessionID("s-old"), services: services("older"))
        let older = await keeper.playerServiceGenerationsForTesting().services[player]
        _ = try await keeper.join(session: playerSession(), clientID: client, sessionID: session, services: services("newer"))
        await expectAligned(keeper, "rejoined")
        #expect(await keeper.playerServiceGenerationsForTesting().services[player] != older, "the newer entry's generation")
        #expect(PlayerServicesLeaveLog.tags(land) == ["older"], "the kick's OnLeave resolvers saw the older services")
        _ = try await keeper.handleActionEnvelope(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().seen.last == "action:newer")
    }

    @Test("A session join whose OnJoin resolver fails rolls the table back with its entry")
    func sessionJoinRollback() async throws {
        let keeper = await makeKeeper("ps-session-rollback")
        // The resolver's own error, so a join that fails before its insert doesn't pass.
        let error = await #expect(throws: (any Error).self) {
            _ = try await keeper.join(session: playerSession(), clientID: client, sessionID: session, services: services("fail"))
        }
        guard case let .resolverFailed(_, underlying)? = error as? ResolverExecutionError else {
            Issue.record("expected the OnJoin resolver's failure, got \(String(describing: error))")
            return
        }
        #expect(underlying is PlayerServicesJoinRefused)
        let generations = await keeper.playerServiceGenerationsForTesting()
        #expect(generations.players.isEmpty)
        #expect(generations.services == generations.players)
    }

    @Test("A failed land clears the table, as it clears the player table")
    func failedLandClearsTheTable() async throws {
        let keeper = await makeKeeper("ps-fail-land")
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("player"))
        await keeper.failLandForTesting(LandFailure(kind: .syncPlan, detail: "test", position: LandFailurePosition(stage: .syncPhase)))
        let generations = await keeper.playerServiceGenerationsForTesting()
        #expect(generations.services.isEmpty)
        #expect(generations.players.isEmpty)
    }

    // The other sites write the two tables in the same lines as these, and the PR's audit
    // lists them: the drain rollbacks of both joins (a join whose resolvers end after a drain
    // began), the failed initialization's clear and a re-evaluation keeper's `forceShutdown`.

    @Test("After the land stops, the table is empty, as the player table is")
    func stopClearsTheTable() async throws {
        let keeper = await makeKeeper("ps-stop")
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: services("player"))
        await keeper.forceShutdown()
        let generations = await keeper.playerServiceGenerationsForTesting()
        #expect(generations.services.isEmpty)
        #expect(generations.players.isEmpty)
    }
}
