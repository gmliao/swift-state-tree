// Tests/SwiftStateTreeTests/DecimalRegistrationTests.swift
//
// #597: `Decimal` has no wire form. The macros refuse a `Decimal` the declared syntax shows
// (RefusedFieldTypeDiagnosticTests); registration refuses what the syntax doesn't show, such as
// a typealias, in a synced state field. A server-only field may hold one. A payload can't hold
// one at all: `Decimal` isn't plain data, so a payload field of it, under any spelling, doesn't
// compile (scripts/must-not-compile/decimal-alias-*.swift).

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// The macros see only the spelling, so a typealias passes them: registration refuses it.
typealias DecimalAlias = Decimal

/// A plain struct, reached through a synced field.
struct DecimalHolder: Codable, Equatable, Sendable, Hashable {
    var amount: Decimal = 0
}

@StateNodeBuilder
struct DecimalSyncedRoot: StateNodeProtocol {
    @Sync(.broadcast)
    var price: DecimalAlias = 0

    @Sync(.broadcast)
    var maybe: DecimalAlias? = nil

    @Sync(.broadcast)
    var list: [DecimalAlias] = []

    @Sync(.broadcast)
    var unique: Set<DecimalAlias> = []

    @Sync(.broadcast)
    var byName: [String: DecimalAlias] = [:]

    @Sync(.broadcast)
    var holder: DecimalHolder = DecimalHolder()

    @Sync(.serverOnly)
    var hidden: Decimal = 0
}

@StateNodeBuilder
struct DecimalHiddenRoot: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    @Sync(.serverOnly)
    var hidden: Decimal = 0
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
    @Test("A synced Decimal behind a typealias is refused at each shape; a server-only one is not (an @Internal one doesn't compile: Decimal isn't PlainData)")
    func syncedDecimalFields() {
        #expect(SyncRegistration.problems(DecimalSyncedRoot.self) == [
            .decimalField(path: "DecimalSyncedRoot.price"),
            .decimalField(path: "DecimalSyncedRoot.maybe"),
            .decimalField(path: "DecimalSyncedRoot.list[*]"),
            .decimalField(path: "DecimalSyncedRoot.unique[*]"),
            .decimalField(path: "DecimalSyncedRoot.byName[*]"),
            .decimalField(path: "DecimalSyncedRoot.holder.amount"),
        ])
        #expect(SyncRegistration.problems(DecimalHiddenRoot.self).isEmpty)
        let message = SyncRegistrationError.Problem.decimalField(path: "Root.price").description
        #expect(message.contains("Root.price") && message.contains("integer of the smallest unit"), "\(message)")
    }

    @Test("A land with no Decimal on the wire registers")
    func cleanLandRegisters() throws {
        let definition = Land("decimal-clean", using: DecimalHiddenRoot.self) {
            ServerEvents { Register(DecimalCleanEvent.self) }
            Rules {}
        }
        try definition.validateForRegistration(context: .encodingIndependent)
    }
}
