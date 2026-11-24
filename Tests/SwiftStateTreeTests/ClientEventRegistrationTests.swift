// Tests for #771 §3.3: a land's client event registrations (`ClientEvents { Register(X.self) }`)
// and its `HandleEvent` handlers must agree. A registered event without a handler, or a handled
// event that isn't registered, is refused at registration and by a directly built keeper,
// instead of failing per event at intake. Also: handlers declared inside nested `Rules` are kept
// (§3.1, the builder flattens `Rules`), and a node the builder doesn't recognize is refused, not
// dropped with its handlers (#794).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ClientEventRegistrationState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    public init() {}
}

/// Another land's State: its nodes aren't this land's.
@StateNodeBuilder
struct CEROtherState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    public init() {}
}

/// A node type `LandBuilder` has no case for.
struct CERStrayNode: LandNode {}


@Payload
struct CERHandledEvent: ClientEventPayload {
    let amount: Int
}

@Payload
struct CERSecondEvent: ClientEventPayload {
    let amount: Int
}

@Payload
struct CERUnhandledEvent: ClientEventPayload {
    let amount: Int
}

@Payload
struct CERUnregisteredEvent: ClientEventPayload {
    let amount: Int
}

@Payload
struct CERServerEvent: ServerEventPayload {
    let amount: Int
}

@Payload
struct CERAck: ResponsePayload {
    let total: Int
}

@Payload
struct CERInnerAction: ActionPayload {
    typealias Response = CERAck
    let amount: Int
}

@Payload
struct CERDeepAction: ActionPayload {
    typealias Response = CERAck
    let amount: Int
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// Registers `CERHandledEvent` and `CERUnhandledEvent`, and handles only the first.
private func registeredWithoutHandlerLand() -> LandDefinition<ClientEventRegistrationState> {
    Land("cer-registered-no-handler", using: ClientEventRegistrationState.self) {
        ClientEvents {
            Register(CERHandledEvent.self)
            Register(CERUnhandledEvent.self)
        }
        Rules {
            HandleEvent(CERHandledEvent.self) { (state: inout ClientEventRegistrationState, event: CERHandledEvent, _: LandContext) in
                state.total += event.amount
            }
        }
    }
}

/// Registers `CERHandledEvent`, and handles it and `CERUnregisteredEvent`.
private func handledNotRegisteredLand() -> LandDefinition<ClientEventRegistrationState> {
    Land("cer-handled-not-registered", using: ClientEventRegistrationState.self) {
        ClientEvents { Register(CERHandledEvent.self) }
        Rules {
            HandleEvent(CERHandledEvent.self) { (state: inout ClientEventRegistrationState, event: CERHandledEvent, _: LandContext) in
                state.total += event.amount
            }
            HandleEvent(CERUnregisteredEvent.self) { (state: inout ClientEventRegistrationState, event: CERUnregisteredEvent, _: LandContext) in
                state.total += event.amount
            }
        }
    }
}

/// The registration error a land's check throws, or a recorded issue when it throws none.
private func registrationError(
    _ definition: LandDefinition<ClientEventRegistrationState>
) throws -> LandRegistrationError {
    try #require(throws: LandRegistrationError.self) {
        try definition.validateForRegistration(context: .encodingIndependent)
    }
}

/// The registration error a directly built keeper holds as its initialization failure. A leave
/// throws it (a join is only denied: the failed land is shutting down).
private func keeperFailure(
    _ definition: LandDefinition<ClientEventRegistrationState>
) async throws -> LandRegistrationError {
    let keeper = LandKeeper<ClientEventRegistrationState>(
        definition: definition,
        initialState: ClientEventRegistrationState(),
        autoStartLoops: false
    )
    let failure = try await #require(throws: LandInitializationError.self) {
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
    }
    return try #require(failure.underlying as? LandRegistrationError)
}

@Suite("Client event registrations agree with their handlers (#771 §3.3)")
struct ClientEventRegistrationTests {
    @Test("A registered client event without a HandleEvent is refused at registration and by a directly built keeper")
    func refusesRegisteredClientEventWithoutHandler() async throws {
        let unhandled = String(reflecting: CERUnhandledEvent.self)
        let expected = ["\(unhandled): registered, no HandleEvent"]

        let error = try registrationError(registeredWithoutHandlerLand())
        #expect(error.landType == "cer-registered-no-handler")
        #expect(error.clientEventMismatches == expected)
        #expect(error.description.contains(expected[0]))
        #expect(!error.description.contains(String(reflecting: CERHandledEvent.self)), "the handled event isn't named")

        let held = try await keeperFailure(registeredWithoutHandlerLand())
        #expect(held.landType == "cer-registered-no-handler")
        #expect(held.clientEventMismatches == expected)
        #expect(held.description.contains(expected[0]))
    }

    @Test("A handled client event that isn't registered is refused at registration and by a directly built keeper")
    func refusesHandledClientEventNotRegistered() async throws {
        let unregistered = String(reflecting: CERUnregisteredEvent.self)
        let expected = ["\(unregistered): handled, not in ClientEvents"]

        let error = try registrationError(handledNotRegisteredLand())
        #expect(error.landType == "cer-handled-not-registered")
        #expect(error.clientEventMismatches == expected)
        #expect(error.description.contains(expected[0]))
        #expect(!error.description.contains(String(reflecting: CERHandledEvent.self)), "the registered event isn't named")

        let held = try await keeperFailure(handledNotRegisteredLand())
        #expect(held.clientEventMismatches == expected)
        #expect(held.description.contains(expected[0]))
    }

    @Test("A land whose registrations and handlers agree registers, and keeps its registration order")
    func matchingRegistrationsAndHandlersRegister() async throws {
        let definition = Land("cer-matching", using: ClientEventRegistrationState.self) {
            ClientEvents {
                Register(CERSecondEvent.self)
                Register(CERHandledEvent.self)
            }
            Rules {
                HandleEvent(CERHandledEvent.self) { (state: inout ClientEventRegistrationState, event: CERHandledEvent, _: LandContext) in
                    state.total += event.amount
                }
                HandleEvent(CERSecondEvent.self) { (state: inout ClientEventRegistrationState, event: CERSecondEvent, _: LandContext) in
                    state.total += event.amount
                }
            }
        }
        try definition.validateForRegistration(context: .encodingIndependent)
        #expect(definition.clientEventRegistry.registered.map { ObjectIdentifier($0.type) }
            == [ObjectIdentifier(CERSecondEvent.self), ObjectIdentifier(CERHandledEvent.self)])
        let schema = try #require(try SchemaExtractor.extract(from: definition).lands[definition.id])
        #expect(schema.clientEvents.count == 2)

        let keeper = LandKeeper<ClientEventRegistrationState>(
            definition: definition,
            initialState: ClientEventRegistrationState(),
            autoStartLoops: false
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
    }

    @Test("Handlers declared in Rules, and in Rules inside Rules, are in the definition and handle their input")
    func nestedRulesHandlersAreKept() async throws {
        let definition = Land("cer-nested-rules", using: ClientEventRegistrationState.self) {
            Rules {
                HandleAction(CERInnerAction.self) { (state: inout ClientEventRegistrationState, action: CERInnerAction, _: LandContext) in
                    state.total += action.amount
                    return CERAck(total: state.total)
                }
                Rules {
                    HandleAction(CERDeepAction.self) { (state: inout ClientEventRegistrationState, action: CERDeepAction, _: LandContext) in
                        state.total += action.amount * 10
                        return CERAck(total: state.total)
                    }
                }
            }
        }
        #expect(definition.actionHandlers.count == 2)
        try definition.validateForRegistration(context: .encodingIndependent)

        let keeper = LandKeeper<ClientEventRegistrationState>(
            definition: definition,
            initialState: ClientEventRegistrationState(),
            autoStartLoops: false
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        #expect(try await ackTotal(send(keeper, CERInnerAction(amount: 1))) == 1)
        #expect(try await ackTotal(send(keeper, CERDeepAction(amount: 2))) == 21)
    }

    @Test("A registration and its HandleEvent agree across nested Rules; a nested HandleEvent with no registration is still refused")
    func agreementAcrossNestedRules() throws {
        let agreeing = Land("cer-nested-agree", using: ClientEventRegistrationState.self) {
            ClientEvents { Register(CERHandledEvent.self) }
            Rules {
                Rules {
                    HandleEvent(CERHandledEvent.self) { state, event, _ in state.total += event.amount }
                }
            }
        }
        #expect(agreeing.clientEventMismatches.isEmpty)
        try agreeing.validateForRegistration(context: .encodingIndependent)

        let nestedUnregistered = Land("cer-nested-unregistered", using: ClientEventRegistrationState.self) {
            ClientEvents { Register(CERHandledEvent.self) }
            Rules {
                HandleEvent(CERHandledEvent.self) { state, event, _ in state.total += event.amount }
                Rules {
                    HandleEvent(CERUnregisteredEvent.self) { state, event, _ in state.total += event.amount }
                }
            }
        }
        let error = try registrationError(nestedUnregistered)
        #expect(error.clientEventMismatches == ["\(String(reflecting: CERUnregisteredEvent.self)): handled, not in ClientEvents"])
    }

    @Test("A type registered twice is named once when it has no handler, and agrees once handled")
    func typeRegisteredTwice() throws {
        let unhandled = Land("cer-twice-unhandled", using: ClientEventRegistrationState.self) {
            ClientEvents {
                Register(CERUnhandledEvent.self)
                Register(CERUnhandledEvent.self)
            }
            Rules {}
        }
        #expect(unhandled.clientEventMismatches == ["\(String(reflecting: CERUnhandledEvent.self)): registered, no HandleEvent"])

        let handled = Land("cer-twice-handled", using: ClientEventRegistrationState.self) {
            ClientEvents {
                Register(CERHandledEvent.self)
                Register(CERHandledEvent.self)
            }
            Rules {
                HandleEvent(CERHandledEvent.self) { state, event, _ in state.total += event.amount }
            }
        }
        #expect(handled.clientEventMismatches.isEmpty)
    }

    @Test("With records replayed, a mismatched land reports the mismatch, and the fingerprint isn't computed in its place")
    func mismatchUnderReplayReportsTheMismatch() throws {
        // The server input holds a type named like the state's (#602): computed, the fingerprint
        // would report that collision too.
        let land = Land("cer-replay-mismatch", using: SchemaNameFirstLandState.self) {
            Rules {
                HandleServerInput(SchemaNameC.Holder.self) { _, _, _ in }
                HandleEvent(CERUnregisteredEvent.self) { _, _, _ in }
            }
        }
        let error = try #require(throws: LandRegistrationError.self) {
            try land.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(error.clientEventMismatches == ["\(String(reflecting: CERUnregisteredEvent.self)): handled, not in ClientEvents"])
        #expect(error.typeNameCollisions.isEmpty, "the fingerprint waits for the other rows: \(error)")
        #expect(error.schemaFingerprint == nil)
    }

    @Test("With records replayed, a land refused for a mismatch or an unrecognized node still reports its server event without a decoder")
    func refusalUnderReplayKeepsTheDecoderRow() throws {
        // The fingerprint waits for the other rows. Computed anyway, its schema walk re-runs
        // registration, whose error leaves before the decoder row (EV8) is computed.
        let mismatched = Land("cer-replay-mismatch-ev8", using: ClientEventRegistrationState.self) {
            Rules {
                HandleEvent(CERUnregisteredEvent.self) { state, event, _ in state.total += event.amount }
            }
        }
        .replacingServerEventRegistry(cerServerEventsWithoutDecoder())
        let mismatch = try #require(throws: LandRegistrationError.self) {
            try mismatched.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(mismatch.clientEventMismatches == ["\(String(reflecting: CERUnregisteredEvent.self)): handled, not in ClientEvents"])
        #expect(mismatch.serverEventsWithoutDecoder.count == 1, "\(mismatch)")
        #expect(mismatch.schemaFingerprint == nil)

        let stray = LandBuilder.build(id: "cer-replay-unrecognized-ev8", stateType: ClientEventRegistrationState.self, nodes: [CERStrayNode()])
            .replacingServerEventRegistry(cerServerEventsWithoutDecoder())
        let unrecognized = try #require(throws: LandRegistrationError.self) {
            try stray.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(unrecognized.unrecognizedNodes == [String(reflecting: CERStrayNode.self)])
        #expect(unrecognized.serverEventsWithoutDecoder.count == 1, "\(unrecognized)")
        #expect(unrecognized.schemaFingerprint == nil)
    }

    @Test("A node the builder doesn't recognize (another State's, or an unknown type) is refused at registration and by a directly built keeper, not dropped")
    func unrecognizedNodesAreRefused() async throws {
        let foreign = OnJoin { (state: inout CEROtherState, _: LandContext) in state.count += 1 }
        let nodes: [LandNode] = [foreign, CERStrayNode()]
        func definition() -> LandDefinition<ClientEventRegistrationState> {
            LandBuilder.build(id: "cer-unrecognized", stateType: ClientEventRegistrationState.self, nodes: nodes)
        }
        let expected = [String(reflecting: OnJoinNode<CEROtherState>.self), String(reflecting: CERStrayNode.self)]
        #expect(definition().unrecognizedNodes == expected)

        let error = try registrationError(definition())
        #expect(error.unrecognizedNodes == expected)
        #expect(error.description.contains(expected[0]), "\(error)")

        let held = try await keeperFailure(definition())
        #expect(held.unrecognizedNodes == expected)
    }
}

/// A server event registry holding one event through the public descriptor init, which has no
/// decoder, so a replay can't decode it (EV8).
private func cerServerEventsWithoutDecoder() -> EventRegistry<AnyServerEvent> {
    EventRegistry(registered: [
        AnyEventDescriptor(type: CERServerEvent.self, eventName: EventRegistry<AnyServerEvent>.eventName(for: CERServerEvent.self), direction: .server)
    ])
}

private func send(_ keeper: LandKeeper<ClientEventRegistrationState>, _ action: any ActionPayload) async throws -> AnyCodable {
    try await keeper.handleActionEnvelope(
        ActionEnvelope(typeIdentifier: String(describing: type(of: action)), payload: AnyCodable(action)),
        playerID: p1, clientID: c1, sessionID: s1
    )
}

/// The ack's total in an action's response, nil when there is none.
private func ackTotal(_ response: AnyCodable) -> Int? {
    let ack = (response.base as? CERAck) ?? ((response.base as? AnyCodable)?.base as? CERAck)
    return ack?.total
}
