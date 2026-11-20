// Tests/SwiftStateTreeTests/DecimalRegistrationTests.swift
//
// #597: `Decimal` has no wire form. The macros refuse a `Decimal` the declared syntax shows
// (RefusedFieldTypeDiagnosticTests); registration refuses what the syntax doesn't show, such as
// a typealias, wherever it would reach the wire: a synced state field and a payload field. A
// server-only or `@Internal` field may hold one. Resolver outputs don't reach the wire; their
// replay record is #707.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// The macros see only the spelling, so a typealias passes them: registration refuses it.
typealias DecimalAlias = Decimal

/// A plain struct, reached through a synced field or a payload field.
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

    @Internal
    var scratch: Decimal = 0
}

@StateNodeBuilder
struct DecimalHiddenRoot: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    @Sync(.serverOnly)
    var hidden: Decimal = 0

    @Internal
    var scratch: Decimal = 0
}

@Payload
struct DecimalPriceEvent: ServerEventPayload {
    let amount: DecimalAlias
    let tags: [String: DecimalAlias]
}

@Payload
struct DecimalBidEvent: ClientEventPayload {
    let offers: [DecimalAlias]
}

@Payload
struct DecimalBuyResponse: ResponsePayload {
    let totals: [DecimalAlias]
}

/// A nested type that lists its stored fields, so the walk sees them.
@SnapshotConvertible
struct DecimalLine: Codable, Sendable {
    let amount: DecimalAlias
}

@Payload
struct DecimalBuyAction: ActionPayload {
    typealias Response = DecimalBuyResponse
    let line: DecimalLine
}

/// A nested plain `Codable` type lists no fields, so registration doesn't look into it: its
/// `Decimal` fails at the first send (`DecimalSendTests`).
@Payload
struct DecimalGapEvent: ServerEventPayload {
    let holder: DecimalHolder
}

@Payload
struct DecimalRefund: ServerInputPayload {
    let amount: DecimalAlias
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
    @Test("A synced Decimal behind a typealias is refused at each shape; a server-only or @Internal one is not")
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

    @Test("A Decimal behind a typealias in an event, an action, a response or a server input is refused, naming each path")
    func payloadDecimalFields() throws {
        let definition = Land("decimal-payloads", using: DecimalHiddenRoot.self) {
            ClientEvents { Register(DecimalBidEvent.self) }
            ServerEvents {
                Register(DecimalPriceEvent.self)
                Register(DecimalCleanEvent.self)
            }
            Rules {
                HandleAction(DecimalBuyAction.self) { (_: inout DecimalHiddenRoot, _: DecimalBuyAction, _: LandContext) in
                    DecimalBuyResponse(totals: [])
                }
                HandleServerInput(DecimalRefund.self) { (_: inout DecimalHiddenRoot, _: DecimalRefund, _: LandContext) in }
            }
        }
        let error = try #require(registrationError(definition))
        #expect(error.decimalFields == [
            "client event DecimalBidEvent.offers[*]",
            "server event DecimalPriceEvent.amount",
            "server event DecimalPriceEvent.tags[*]",
            "action DecimalBuyAction.line.amount",
            "response DecimalBuyResponse of action DecimalBuyAction.totals[*]",
            "server input DecimalRefund.amount",
        ], "\(error.decimalFields)")
        #expect(error.sync == nil)
        #expect(error.description.contains("integer of the smallest unit"), "\(error)")
    }

    @Test("A nested plain Codable type isn't looked into: its Decimal is left to the send-time refusal")
    func nestedPlainTypeIsNotWalked() {
        #expect(DecimalFields.payloadPaths(in: DecimalGapEvent.self, root: "e").isEmpty)
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
