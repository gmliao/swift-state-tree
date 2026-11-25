// Tests/SwiftStateTreeTests/ActionHandlerIndexTests.swift
//
// #700 K1b-1, F9: a queued action names its handler by a position in the land's handlers. The
// position is meaningful only in this process, so the type isn't Codable (pinned here, in the
// package: the must-not-compile harness builds an external package, which can't name a package
// type). An index outside the handlers is skipped at apply, with a log, as a missing handler is.

import Foundation
import Testing
@testable import SwiftStateTree

@Payload
struct HandlerIndexCodableControl: ActionPayload {
    typealias Response = HandlerIndexAck
    let n: Int
}

@Payload
struct HandlerIndexAck: ResponsePayload {
    let n: Int
}

@StateNodeBuilder
struct HandlerIndexState: StateNodeProtocol {
    @Sync(.broadcast)
    var applied: [Int] = []

    public init() {}
}

@Suite("A queued action's handler index (#700 K1b-1, F9)")
struct ActionHandlerIndexTests {
    @Test("The index isn't Codable; a Codable type passes the same casts")
    func handlerIndexIsNotCodable() {
        #expect(!(ActionHandlerIndex.self is any Encodable.Type))
        #expect(!(ActionHandlerIndex.self is any Decodable.Type))
        // Positive control: the casts do find a conformance when there is one.
        #expect(HandlerIndexCodableControl.self is any Encodable.Type)
        #expect(HandlerIndexCodableControl.self is any Decodable.Type)
    }

    /// The land, and a recording keeper on it.
    private func makeKeeper() async -> (LandDefinition<HandlerIndexState>, LandKeeper<HandlerIndexState>) {
        let definition = Land("handler-index", using: HandlerIndexState.self) {
            Lifetime { Tick(every: .seconds(3600)) { _, _ in } }
            Rules {
                HandleAction(HandlerIndexCodableControl.self) { state, action, _ in
                    state.applied.append(action.n)
                    return HandlerIndexAck(n: action.n)
                }
            }
        }
        let keeper = LandKeeper<HandlerIndexState>(
            definition: definition,
            initialState: HandlerIndexState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false,
            landID: "handler-index:local"
        )
        await keeper.awaitInitialization()
        return (definition, keeper)
    }

    @Test("An index outside the land's action handlers is skipped at apply, and nothing is recorded",
          arguments: [HandlerIndexOutOfRange.pastTheEnd, .negative])
    func outOfRangeIndexIsSkipped(_ position: HandlerIndexOutOfRange) async throws {
        let (definition, keeper) = await makeKeeper()
        let item = PendingActionItemForTesting.make(
            sequence: 1,
            action: HandlerIndexCodableControl(n: 7),
            handlerIndex: ActionHandlerIndex(position.position(handlers: definition.actionHandlers.count))
        )
        let applied = try await keeper.applyPendingItemForTesting(.action(item))
        #expect(applied.isSkipped)
        #expect(applied.recordedActions.isEmpty)
        #expect(await keeper.currentState().applied.isEmpty)
        await keeper.forceShutdown()
    }

    @Test("A hand-built item with no index runs the handler its value's type names, and is recorded")
    func itemWithoutAnIndexRunsTheValueTypesHandler() async throws {
        let (_, keeper) = await makeKeeper()
        let item = PendingActionItemForTesting.make(sequence: 1, action: HandlerIndexCodableControl(n: 7), handlerIndex: nil)
        let applied = try await keeper.applyPendingItemForTesting(.action(item))
        #expect(!applied.isSkipped)
        #expect(applied.recordedActions.map(\.typeIdentifier) == [String(describing: HandlerIndexCodableControl.self)])
        #expect(await keeper.currentState().applied == [7])
        await keeper.forceShutdown()
    }
}

/// An index outside the handlers, on either side.
enum HandlerIndexOutOfRange: Sendable, CustomTestStringConvertible {
    case pastTheEnd
    case negative

    func position(handlers count: Int) -> Int {
        switch self {
        case .pastTheEnd: count
        case .negative: -1
        }
    }

    var testDescription: String {
        switch self {
        case .pastTheEnd: "past the end"
        case .negative: "negative"
        }
    }
}

/// A queued action with a given handler index, through the package init.
private enum PendingActionItemForTesting {
    static func make<A: ActionPayload>(
        sequence: Int64,
        action: A,
        handlerIndex: ActionHandlerIndex?
    ) -> LandKeeper<HandlerIndexState>.PendingActionItem {
        LandKeeper<HandlerIndexState>.PendingActionItem(
            sequence: sequence,
            decoded: .value(action),
            handlerIndex: handlerIndex,
            recorded: nil,
            playerID: PlayerID("p1"),
            clientID: ClientID("c1"),
            sessionID: SessionID("s1"),
            heldResolverOutputs: [:],
            resolvedAtTick: 0
        )
    }
}
