// Tests/SwiftStateTreeTests/LegacyJoinAdmissionTests.swift
//
// #903: `LandKeeper.join(playerID:clientID:sessionID:services:)` is the short way to add a player.
// It forwards to `join(session:…)`, so it runs the land's CanJoin and the player limit
// (`MaxPlayers`), as the transport's join does. A denial throws `JoinError.custom` with CanJoin's
// reason. The lands are tickless and don't start their loops: each join returns once its OnJoin
// has run.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct LegacyJoinState: StateNodeProtocol {
    /// "join:<player>:<client>" and "leave:<player>:<client>", in the order the handlers ran.
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

/// A land that records its joins and leaves. CanJoin denies `banned` with a reason and maps
/// `alias` to `mapped`.
private func makeLegacyJoinDefinition(maxPlayers: Int) -> LandDefinition<LegacyJoinState> {
    Land("legacy-join-admission", using: LegacyJoinState.self) {
        AccessControl { MaxPlayers(maxPlayers) }
        Rules {
            CanJoin { _, session, _ in
                if session.playerID == "banned" { return .deny(reason: "banned by CanJoin") }
                if session.playerID == "alias" { return .allow(playerID: PlayerID("mapped")) }
                return .allow(playerID: PlayerID(session.playerID))
            }
            OnJoin { state, ctx in
                state.log.append("join:\(ctx.playerID.rawValue):\(ctx.clientID.rawValue)")
            }
            OnLeave { state, ctx in
                state.log.append("leave:\(ctx.playerID.rawValue):\(ctx.clientID.rawValue)")
            }
        }
    }
}

private func makeLegacyJoinKeeper(maxPlayers: Int = 4) -> LandKeeper<LegacyJoinState> {
    LandKeeper<LegacyJoinState>(
        definition: makeLegacyJoinDefinition(maxPlayers: maxPlayers),
        initialState: LegacyJoinState(),
        autoStartLoops: false
    )
}

private func legacyJoin(_ keeper: LandKeeper<LegacyJoinState>, _ player: String, client: String) async throws {
    try await keeper.join(playerID: PlayerID(player), clientID: ClientID(client), sessionID: SessionID(client))
}

@Suite("join(playerID:) goes through the land's admission (#903)", .timeLimit(.minutes(1)))
struct LegacyJoinAdmissionTests {
    @Test("J1: a CanJoin denial throws JoinError.custom with its reason, and the land gets no player")
    func canJoinDenialThrows() async throws {
        let keeper = makeLegacyJoinKeeper()
        do {
            try await legacyJoin(keeper, "banned", client: "c0")
            Issue.record("the denied join returned normally")
        } catch JoinError.custom(let reason) {
            #expect(reason == "banned by CanJoin")
        }
        #expect(await keeper.playerCount() == 0)
        #expect(await keeper.currentState().log.isEmpty)
        await keeper.forceShutdown()
    }

    @Test("J2: a join past MaxPlayers throws roomIsFull")
    func playerLimitApplies() async throws {
        let keeper = makeLegacyJoinKeeper(maxPlayers: 1)
        try await legacyJoin(keeper, "p1", client: "c1")
        do {
            try await legacyJoin(keeper, "p2", client: "c2")
            Issue.record("the join past the limit returned normally")
        } catch JoinError.roomIsFull {
        }
        #expect(await keeper.playerCount() == 1)
        #expect(await keeper.currentState().log == ["join:p1:c1"])
        await keeper.forceShutdown()
    }

    @Test("J3: the player ID CanJoin maps to is the one admitted")
    func mappedPlayerIDIsAdmitted() async throws {
        let keeper = makeLegacyJoinKeeper()
        try await legacyJoin(keeper, "alias", client: "c1")
        #expect(await keeper.playerCount() == 1)
        #expect(await keeper.currentState().log == ["join:mapped:c1"])
        // The entry is the mapped player's: its leave runs, the original ID's would find none.
        try await keeper.leave(playerID: PlayerID("mapped"), clientID: ClientID("c1"), sessionID: SessionID("c1"))
        #expect(await keeper.playerCount() == 0)
        #expect(await keeper.currentState().log == ["join:mapped:c1", "leave:mapped:c1"])
        await keeper.forceShutdown()
    }

    @Test("J4: a duplicate login still kicks the old session: OnLeave runs once and the entry is the new client's")
    func duplicateLoginKicksOldSession() async throws {
        let keeper = makeLegacyJoinKeeper()
        try await legacyJoin(keeper, "p1", client: "c-a")
        try await legacyJoin(keeper, "p1", client: "c-b")
        let log = await keeper.currentState().log
        #expect(log.filter { $0.hasPrefix("leave:") } == ["leave:p1:c-a"], "\(log)")
        #expect(log.last == "join:p1:c-b", "\(log)")
        #expect(await keeper.playerCount() == 1)
        await keeper.forceShutdown()
    }
}
