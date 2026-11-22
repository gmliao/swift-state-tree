// Tests/SwiftStateTreeTests/ReevaluationLiveInputTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

private func makeReevaluationKeeper(tick: Bool) -> LandKeeper<RoutingPinState> {
    LandKeeper<RoutingPinState>(
        definition: makeRoutingPinLand(tick: tick), initialState: RoutingPinState(),
        mode: .reevaluation, autoStartLoops: false
    )
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// A re-evaluation keeper replays recorded inputs and doesn't route through turns. A live join or
/// leave on one, tick or tickless, only updates observer membership: the player is added or
/// removed, no OnJoin / OnLeave runs and no input is queued. Its other live entries refuse it
/// without applying anything. How a re-evaluation keeper takes (or can't take) live input is for
/// #612 to design; these pin today's behaviour so a change to it is deliberate.
@Suite("A re-evaluation keeper takes live inputs as observer membership only (#546 L2d-3)", .timeLimit(.minutes(1)))
struct ReevaluationLiveInputTests {
    @Test("join(playerID:) then leave adds and removes an observer, with no handler and no queued input", arguments: [false, true])
    func joinAndLeaveUpdateObserversOnly(tick: Bool) async throws {
        let keeper = makeReevaluationKeeper(tick: tick)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.playerCount() == 1)
        #expect(await keeper.pendingItemSequencesForTesting().isEmpty, "a re-evaluation join queues no input")
        try await keeper.leave(playerID: p1, clientID: c1)
        #expect(await keeper.playerCount() == 0)
        #expect(await keeper.pendingItemSequencesForTesting().isEmpty, "a re-evaluation leave queues no input")
        let lifecycle = await keeper.currentState().log.filter { $0.hasPrefix("join:") || $0.hasPrefix("leave:") }
        #expect(lifecycle.isEmpty, "no OnJoin / OnLeave runs on a re-evaluation keeper, ran \(lifecycle)")
    }

    @Test("join(session:) adds an observer, with no handler and no queued input", arguments: [false, true])
    func sessionJoinUpdatesObserversOnly(tick: Bool) async throws {
        let keeper = makeReevaluationKeeper(tick: tick)
        _ = try await keeper.join(
            session: PlayerSession(playerID: "p1"), clientID: c1, sessionID: s1, services: LandServices()
        )
        #expect(await keeper.playerCount() == 1)
        #expect(await keeper.pendingItemSequencesForTesting().isEmpty, "a re-evaluation session join queues no input")
        let lifecycle = await keeper.currentState().log.filter { $0.hasPrefix("join:") }
        #expect(lifecycle.isEmpty, "no OnJoin runs on a re-evaluation keeper, ran \(lifecycle)")
    }

    @Test("A leave for a player who isn't there is a no-op", arguments: [false, true])
    func leaveOfAbsentPlayerIsNoOp(tick: Bool) async throws {
        let keeper = makeReevaluationKeeper(tick: tick)
        try await keeper.leave(playerID: p1, clientID: c1)
        #expect(await keeper.playerCount() == 0)
        #expect(await keeper.pendingItemSequencesForTesting().isEmpty)
    }

    @Test("An action, a client event and a server input are refused without applying anything")
    func otherEntriesRefuse() async throws {
        let keeper = makeReevaluationKeeper(tick: false)
        let action = ActionEnvelope(
            typeIdentifier: String(describing: RoutingPinAction.self), payload: AnyCodable(RoutingPinAction(tag: "a"))
        )
        _ = try await keeper.handleActionEnvelope(action, playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.handleClientEvent(AnyClientEvent(RoutingPinClientEvent(tag: "e")), playerID: p1, clientID: c1, sessionID: s1)
        guard case .refused(.notLive) = await keeper.submitServerInput(RoutingPinInput(tag: "i")) else {
            Issue.record("a server input on a re-evaluation keeper must be refused .notLive")
            return
        }
        #expect(await keeper.currentState().log.isEmpty)
    }
}
