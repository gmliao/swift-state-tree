// Tests/SwiftStateTreeTests/ReevaluationLiveInputTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

private let liveInputStopMessage = "a re-evaluation keeper takes no live input; it replays recorded passes (#612)"

private func standardError(_ result: ExitTest.Result?) -> String {
    guard let result else { return "" }
    return String(decoding: result.standardErrorContent, as: UTF8.self)
}

private func makeReevaluationKeeper(tick: Bool) -> LandKeeper<RoutingPinState> {
    LandKeeper<RoutingPinState>(
        definition: makeRoutingPinLand(tick: tick), initialState: RoutingPinState(),
        mode: .reevaluation, autoStartLoops: false
    )
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// A re-evaluation keeper replays recorded inputs and doesn't route through turns, so a live
/// input on a tickless one has no path since the legacy pass is gone (#546 L2d-3). A join or a
/// leave stops the process, with its message in every build (`fatalError`); the other live
/// entries already refuse a re-evaluation keeper without applying anything. Exit tests: a
/// change that lets such an input through fails these by name.
@Suite("A re-evaluation keeper refuses live inputs (#546 L2d-3)", .timeLimit(.minutes(1)))
struct ReevaluationLiveInputTests {
    @Test("join(playerID:) on a tickless re-evaluation keeper stops the process")
    func joinStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let keeper = makeReevaluationKeeper(tick: false)
            try? await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        }
        #expect(standardError(result).contains(liveInputStopMessage))
        #expect(standardError(result).contains(".join"))
    }

    @Test("join(session:) on a tickless re-evaluation keeper stops the process")
    func sessionJoinStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let keeper = makeReevaluationKeeper(tick: false)
            _ = try? await keeper.join(
                session: PlayerSession(playerID: "p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"),
                services: LandServices()
            )
        }
        #expect(standardError(result).contains(liveInputStopMessage))
    }

    @Test("leave on a tickless re-evaluation keeper stops the process")
    func leaveStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let keeper = makeReevaluationKeeper(tick: false)
            try? await keeper.leave(playerID: PlayerID("p1"), clientID: ClientID("c1"))
        }
        #expect(standardError(result).contains(liveInputStopMessage))
        #expect(standardError(result).contains(".leave"))
    }

    @Test("A tick re-evaluation keeper still takes a join and a leave (queued for its runTick, #612)")
    func tickLandStillQueues() async {
        await #expect(processExitsWith: .success) {
            let keeper = makeReevaluationKeeper(tick: true)
            try? await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
            try? await keeper.leave(playerID: PlayerID("p1"), clientID: ClientID("c1"))
        }
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
