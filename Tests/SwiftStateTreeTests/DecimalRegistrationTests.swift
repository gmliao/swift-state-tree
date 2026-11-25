// Tests/SwiftStateTreeTests/DecimalRegistrationTests.swift
//
// #597: `Decimal` has no wire form. A state field's value is PlainData, so a synced,
// server-only or internal `Decimal` doesn't compile under any spelling, a typealias included
// (scripts/must-not-compile/state-decimal-alias.swift, state-serveronly-decimal.swift). The
// registration walk stays as the guard for a hand-written PlainData witness, which only a project
// outside this repository's lint can write. A payload can't hold one either
// (scripts/must-not-compile/decimal-alias-*.swift).

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// A plain struct behind a hand-written witness, reached through a synced field.
struct DecimalHolder: Codable, Equatable, Sendable, Hashable {
    var amount: Decimal = 0
}
extension DecimalHolder: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a Decimal in state for the registration walk, which keeps guarding hand-written witnesses

@StateNodeBuilder
struct DecimalSyncedRoot: StateNodeProtocol {
    @Sync(.broadcast)
    var holder: DecimalHolder = DecimalHolder()
    @Sync(.broadcast)
    var maybe: DecimalHolder? = DecimalHolder()
    @Sync(.broadcast)
    var list: [DecimalHolder] = [DecimalHolder()]
    @Sync(.broadcast)
    var unique: Set<DecimalHolder> = [DecimalHolder()]
    @Sync(.broadcast)
    var byName: [String: DecimalHolder] = ["a": DecimalHolder()]
    /// Not reported: the walk follows the fields that reach the wire, as the key and open-type
    /// checks do. Only a hand-written witness gets a `Decimal` here.
    @Sync(.serverOnly)
    var hidden: DecimalHolder = DecimalHolder()
}

@StateNodeBuilder
struct DecimalCleanRoot: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

@Payload
struct DecimalCleanEvent: ServerEventPayload {
    let cents: Int
}

@Payload
struct DecimalCleanResponse: ResponsePayload {
    let cents: Int
}

@Payload
struct DecimalCleanAction: ActionPayload {
    typealias Response = DecimalCleanResponse
    let cents: Int
}

private func registrationError<State: StateNodeProtocol>(_ definition: LandDefinition<State>) -> LandRegistrationError? {
    do {
        try definition.validateForRegistration(context: .encodingIndependent)
        return nil
    } catch let error as LandRegistrationError {
        return error
    } catch {
        Issue.record("expected LandRegistrationError, got \(error)")
        return nil
    }
}

// MARK: - Tests

@Suite("Decimal has no wire form: registration refuses it where it would reach the wire (#597)")
struct DecimalRegistrationTests {
    @Test("A Decimal behind a hand-written PlainData witness is refused at registration, through optionals, arrays, sets and dictionary values; a server-only field is skipped")
    func syncedDecimalFields() {
        #expect(SyncRegistration.problems(DecimalSyncedRoot.self) == [
            .decimalField(path: "DecimalSyncedRoot.holder.amount"),
            .decimalField(path: "DecimalSyncedRoot.maybe.amount"),
            .decimalField(path: "DecimalSyncedRoot.list[*].amount"),
            .decimalField(path: "DecimalSyncedRoot.unique[*].amount"),
            .decimalField(path: "DecimalSyncedRoot.byName[*].amount"),
        ])
        #expect(SyncRegistration.problems(DecimalCleanRoot.self).isEmpty)
        let message = SyncRegistrationError.Problem.decimalField(path: "Root.price").description
        #expect(message.contains("Root.price") && message.contains("integer of the smallest unit"), "\(message)")
    }

    @Test("A land with no Decimal on the wire registers")
    func cleanLandRegisters() throws {
        let definition = Land("decimal-clean", using: DecimalCleanRoot.self) {
            ServerEvents { Register(DecimalCleanEvent.self) }
            Rules {}
        }
        try definition.validateForRegistration(context: .encodingIndependent)
    }
}
