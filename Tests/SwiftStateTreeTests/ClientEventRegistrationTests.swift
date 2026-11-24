// Tests for #771 §3.3: a land's client event registrations (`ClientEvents { Register(X.self) }`)
// and its `HandleEvent` handlers must agree. A registered event without a handler, or a handled
// event that isn't registered, is refused at registration and by a directly built keeper,
// instead of failing per event at intake. Also: handlers declared inside nested `Rules` are kept
// (§3.1, the builder flattens `Rules`).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ClientEventRegistrationState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    public init() {}
}

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
