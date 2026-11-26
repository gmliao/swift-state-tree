// Tests/SwiftStateTreeTests/InputTurnHoldTests.swift
//
// The input turn is a turn body (#700 K1b-5a step 2): it holds the keeper's model while it
// applies its batch. User code it used to run with no access open must stay out of that hold.
// The record's fallback bytes for an input that holds none run the payload's own `encode(to:)`,
// so they are encoded before the body holds the model: a payload whose encode calls back into
// its keeper and reads the state gets a defined outcome, and doesn't trap. (The handlers run
// inside the model access since #877; `KeeperReentryTrapTests` shows that trap.)

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct InputTurnHoldState: StateNodeProtocol {
    @Sync(.broadcast)
    var applied: [Int] = []

    public init() {}
}

@Payload
struct InputTurnHoldAck: ResponsePayload {
    let n: Int
}

/// The keeper a `CallingBackAction`'s encode calls back into, and what the callback read.
final class InputTurnHoldProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var keeper: LandKeeper<InputTurnHoldState>?
    private var reads: [[Int]] = []

    func bind(_ keeper: LandKeeper<InputTurnHoldState>) { lock.withLock { self.keeper = keeper } }
    var boundKeeper: LandKeeper<InputTurnHoldState>? { lock.withLock { keeper } }
    func noteRead(_ applied: [Int]) { lock.withLock { reads.append(applied) } }
    var statesRead: [[Int]] { lock.withLock { reads } }

    /// One probe per test: parallel tests must not share one.
    nonisolated(unsafe) static var current: InputTurnHoldProbe?
}

/// An action whose `encode(to:)` reads its keeper's state synchronously, as a payload's own
/// encoder could.
@Payload
struct CallingBackAction: ActionPayload {
    typealias Response = InputTurnHoldAck
    let n: Int

    func encode(to encoder: Encoder) throws {
        if let probe = InputTurnHoldProbe.current, let keeper = probe.boundKeeper {
            keeper.assumeIsolated { keeper in // lint-allow: turns-isolated: a payload encoder that calls back into its keeper
                probe.noteRead(keeper.currentState().applied)
            }
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(n, forKey: .n)
    }

    private enum CodingKeys: String, CodingKey { case n }
}

private func inputTurnHoldLand() -> LandDefinition<InputTurnHoldState> {
    Land("input-turn-hold", using: InputTurnHoldState.self) {
        Rules {
            HandleAction(CallingBackAction.self) { state, action, _ in
                state.applied.append(action.n)
                return InputTurnHoldAck(n: action.n)
            }
        }
    }
}

/// A queued action that holds no record bytes, as one queued before the land recorded.
private func unrecordedAction(sequence: Int64, n: Int) -> LandKeeper<InputTurnHoldState>.PendingItem {
    .action(LandKeeper<InputTurnHoldState>.PendingActionItem(
        sequence: sequence,
        decoded: .value(CallingBackAction(n: n)),
        handlerIndex: nil,
        recorded: nil,
        playerID: PlayerID("p1"),
        clientID: ClientID("c1"),
        sessionID: SessionID("s1"),
        heldResolverOutputs: [:],
        resolvedAtTick: 0
    ))
}

@Suite("The input turn's hold: user code it newly covers runs before it (#700 K1b-5a)", .serialized, .timeLimit(.minutes(1)))
struct InputTurnHoldTests {
    @Test("A payload whose encode reads the keeper's state runs before the hold: no trap, and the input applies and is recorded")
    func fallbackEncodeRunsBeforeTheHold() async throws {
        let keeper = LandKeeper<InputTurnHoldState>(
            definition: inputTurnHoldLand(),
            initialState: InputTurnHoldState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false,
            landID: "input-turn-hold:\(UUID().uuidString)"
        )
        await keeper.awaitInitialization()
        let probe = InputTurnHoldProbe()
        probe.bind(keeper)
        InputTurnHoldProbe.current = probe
        defer { InputTurnHoldProbe.current = nil }

        let recorded = await keeper.runInputTurnForTesting([unrecordedAction(sequence: 1_000, n: 7), unrecordedAction(sequence: 1_001, n: 8)])

        // Each encode ran once, before the batch applied: it read the state before the turn.
        #expect(probe.statesRead == [[], []])
        #expect(await keeper.currentState().applied == [7, 8])
        #expect(recorded.map(\.sequence) == [1_000, 1_001])
        let payloads = try recorded.map { try JSONSerialization.jsonObject(with: $0.payload) as? [String: Int] }
        #expect(payloads == [["n": 7], ["n": 8]])
        #expect(keeper.failure == nil)
    }
}
