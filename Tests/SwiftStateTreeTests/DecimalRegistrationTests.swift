// Tests/SwiftStateTreeTests/DecimalRegistrationTests.swift
//
// #597: `Decimal` has no wire form, so registration refuses it wherever it would reach the wire:
// a synced state field, and a payload field. A server-only or `@Internal` field may hold one.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// A plain struct, reached through a synced field or a payload field.
struct DecimalHolder: Codable, Equatable, Sendable, Hashable {
    var amount: Decimal = 0
}

@StateNodeBuilder
struct DecimalSyncedRoot: StateNodeProtocol {
    @Sync(.broadcast)
    var price: Decimal = 0

    @Sync(.broadcast)
    var maybe: Decimal? = nil

    @Sync(.broadcast)
    var list: [Decimal] = []

    @Sync(.broadcast)
    var unique: Set<Decimal> = []

    @Sync(.broadcast)
    var byName: [String: Decimal] = [:]

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
    let amount: Decimal
    let tags: [String: Decimal]
}

@Payload
struct DecimalBidEvent: ClientEventPayload {
    let offers: [Decimal]
}

@Payload
struct DecimalBuyResponse: ResponsePayload {
    let totals: [Decimal]
}

/// A nested type that lists its stored fields, so the walk sees them.
@SnapshotConvertible
struct DecimalLine: Codable, Sendable {
    let amount: Decimal
}

@Payload
struct DecimalBuyAction: ActionPayload {
    typealias Response = DecimalBuyResponse
    let line: DecimalLine
}

// Boundary cases of the field probe (after CodableReflection's): a nested plain `Codable`
// type is decoded once through a recording decoder.

/// No defaults: a synthesized `Decodable` needs every key.
struct ProbePlain: Codable, Sendable {
    let amount: Decimal
}

struct ProbeOptional: Codable, Sendable {
    let maybe: Decimal?
}

struct ProbeContainers: Codable, Sendable {
    let byName: [String: [Decimal]]
    let unique: Set<Decimal>
    let grid: [[Decimal]]
}

enum ProbeKind: String, Codable, CaseIterable, Sendable {
    case first, second
}

/// A raw-value enum before the Decimal: its placeholder is its first case.
struct ProbeAfterEnum: Codable, Sendable {
    let kind: ProbeKind
    let amount: Decimal
}

enum ProbeOpenKind: String, Codable, Sendable {
    case only
}

/// An enum with no `CaseIterable`: "" isn't a raw value, so the probe stops at `kind`.
struct ProbeAfterOpenEnum: Codable, Sendable {
    let kind: ProbeOpenKind
    let amount: Decimal
}

/// A type that holds itself, in an array and in an optional dictionary.
struct ProbeNode: Codable, Sendable {
    let value: Decimal
    let children: [ProbeNode]
    let byName: [String: ProbeNode]?
}

/// A hand-written `init(from:)` that validates after `amount`: the fields after the throw aren't
/// asked for.
struct ProbeValidated: Codable, Sendable {
    struct Invalid: Error {}
    let amount: Decimal
    let fee: Decimal

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decode(Decimal.self, forKey: .amount)
        guard amount > 0 else { throw Invalid() }
        fee = try container.decode(Decimal.self, forKey: .fee)
    }
}

@Payload
struct DecimalProbeEvent: ServerEventPayload {
    let plain: ProbePlain
    let optional: ProbeOptional
    let containers: ProbeContainers
    let afterEnum: ProbeAfterEnum
    let node: ProbeNode
}

@Payload
struct DecimalRefund: ServerInputPayload {
    let amount: Decimal
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
    @Test("A synced Decimal is refused at each shape; a server-only or @Internal one is not")
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

    @Test("A Decimal in an event, an action, a response or a server input is refused, naming each path")
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

    @Test("A nested plain Codable type is probed: no defaults, optionals, nested containers, a raw-value enum, recursion")
    func nestedPlainTypesAreProbed() {
        // In the payload's field order (its metadata's). The node's own Decimal is reported once:
        // its children and byName hold the node again, which the walk doesn't re-enter.
        #expect(DecimalFields.payloadPaths(in: DecimalProbeEvent.self, root: "e") == [
            "e.afterEnum.amount",
            "e.containers.byName[*][*]",
            "e.containers.unique[*]",
            "e.containers.grid[*][*]",
            "e.node.value",
            "e.optional.maybe",
            "e.plain.amount",
        ])
        // The struct a synced field holds is probed the same way in a payload.
        #expect(DecimalFields.payloadPaths(in: DecimalHolder.self, root: "h") == ["h.amount"])
    }

    @Test("The probe's limits: fields after a hand-written init's throw, or after an enum without CaseIterable, aren't seen")
    func probeLimits() {
        #expect(DecimalFields.payloadPaths(in: ProbeValidated.self, root: "v") == ["v.amount"],
                "the init throws after amount, so fee isn't asked for")
        #expect(DecimalFields.payloadPaths(in: ProbeAfterOpenEnum.self, root: "o").isEmpty,
                "the enum's placeholder fails, so amount isn't asked for")
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

// MARK: - Resolver outputs

/// A resolver output with a Decimal: the server only reads it, but replay records it.
struct DecimalPriceOutput: ResolverOutput, Equatable {
    let price: Decimal
    let small: Decimal
}

struct DecimalPriceResolver: ContextResolver {
    static func resolve(ctx: ResolverContext) async throws -> DecimalPriceOutput {
        DecimalPriceOutput(price: 1, small: 0)
    }
}

@Suite("A resolver output's Decimal doesn't survive the replay record, so registration refuses it (#597)")
struct DecimalResolverOutputRecordTests {
    static let output = DecimalPriceOutput(price: Decimal(string: "12.345")!, small: Decimal(string: "0.1")!)
    static let recorded = ReevaluationRecordedResolverOutput(
        typeIdentifier: "DecimalPriceOutput", value: AnyCodable(output)
    )

    /// What replay hands the handler: the recorded value through `AnyCodableResolverOutput`
    /// (`LandContext`'s dynamic member lookup re-decodes it through JSON).
    static func replayed(_ entry: ReevaluationRecordedResolverOutput) throws -> DecimalPriceOutput {
        try JSONDecoder().decode(DecimalPriceOutput.self, from: JSONEncoder().encode(entry.value))
    }

    @Test("The saved record keeps the bytes, but in the platform's keyed form, which replay's read refuses")
    func savedRecord() throws {
        let bytes = try CanonicalMessagePack.encode(Self.recorded)
        let decoded = try CanonicalMessagePack.decode(ReevaluationRecordedResolverOutput.self, from: bytes)
        #expect(try CanonicalMessagePack.encode(decoded) == bytes)
        #expect(throws: DecodingError.self) { _ = try Self.replayed(decoded) }
    }

    @Test("A resolver output with a Decimal is refused at registration")
    func resolverOutputIsRefused() {
        let land = Land("decimal-resolver", using: DecimalHiddenRoot.self) {
            Rules {
                HandleAction(DecimalCleanAction.self, resolvers: DecimalPriceResolver.self) { (_: inout DecimalHiddenRoot, _: DecimalCleanAction, _: LandContext) -> DecimalCleanResponse in
                    DecimalCleanResponse(cents: 0)
                }
            }
        }
        #expect(land.payloadDecimalFields() == [
            "resolver output DecimalPriceOutput.price", "resolver output DecimalPriceOutput.small",
        ])
    }
}
