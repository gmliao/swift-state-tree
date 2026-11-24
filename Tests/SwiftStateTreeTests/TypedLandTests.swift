// Tests for #771 D1's `Land(_:using:services:)`: the land records its services type, and its
// body is typed by its State and Services like any land's.

import Testing
@testable import SwiftStateTree

/// A services type for a typed land: nothing reads it until #769 R1.
struct TypedLandTestServices: Sendable {
    let tag: String
}

@Suite("Land(_:using:services:) (#771 D1)")
struct TypedLandTests {
    @Test("A land with services records its services type and infers its handlers' types; a land without records none")
    func servicesTypeIsRecorded() throws {
        let typed = Land("typed-land", using: ClientEventRegistrationState.self, services: TypedLandTestServices.self) {
            Rules {
                HandleAction(CERInnerAction.self) { state, action, _ in
                    state.total += action.amount
                    return CERAck(total: state.total)
                }
            }
        }
        let recorded = try #require(typed.definition.servicesType)
        #expect(ObjectIdentifier(recorded) == ObjectIdentifier(TypedLandTestServices.self))
        #expect(typed.definition.actionHandlers.count == 1)
        try typed.definition.validateForRegistration(context: .encodingIndependent)

        let plain = Land("plain-land", using: ClientEventRegistrationState.self) {
            Rules {
                HandleAction(CERInnerAction.self) { state, _, _ in CERAck(total: state.total) }
            }
        }
        #expect(plain.servicesType == nil)
    }
}
