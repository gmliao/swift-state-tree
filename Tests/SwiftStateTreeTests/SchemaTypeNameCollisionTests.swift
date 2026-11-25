// Tests/SwiftStateTreeTests/SchemaTypeNameCollisionTests.swift
//
// #602: schema definitions are keyed by a type's short name, so two distinct types with one
// name are refused, not merged into one definition.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// Types whose names `SchemaNameB` reuses, with different fields.
enum SchemaNameA {
    @Payload
    struct HitEvent: ClientEventPayload {
        let damage: Int
    }

    @PlainData
    struct Item: Codable, Equatable, Sendable {
        var hp: Int = 0
    }

    /// Declared atomic: sent positionally as its leaves.
    @PlainData
    @SnapshotConvertible(atomic: true)
    struct Spot: Codable, Equatable, Sendable {
        var x: Int32
        var y: Int32

        init() {
            x = 0
            y = 0
        }
    }

    /// Named as the schema's diff placeholder definition.
    @PlainData
    struct StateDiff: Codable, Equatable, Sendable {
        var changed: Int = 0
    }

    /// A collection by `ArrayProtocol`, so the schema converts it inline; as an optional it is
    /// defined under its own name (`innerType`).
    @PlainData
    struct Bag: ArrayProtocol, Codable, Equatable, Sendable {
        typealias Element = Int
        var values: [Int] = []
    }
}

enum SchemaNameB {
    @Payload
    struct HitEvent: ServerEventPayload {
        let source: String
        let critical: Bool
    }

    @PlainData
    struct Item: Codable, Hashable, Sendable {
        var name: String = ""
        var level: Int = 0
    }

    /// Not atomic, with other fields than `SchemaNameA.Spot`.
    @PlainData
    struct Spot: Codable, Equatable, Sendable {
        var label: String = ""
    }

    /// A named object, unlike `SchemaNameA.Bag`.
    @PlainData
    struct Bag: Codable, Equatable, Sendable {
        var label: String = ""
    }
}

/// A server input named like the state's `SchemaNameA.Item`.
enum SchemaNameD {
    @Payload
    struct Item: ServerInputPayload {
        let note: String
    }
}

/// Payloads named like the state types above.
enum SchemaNameC {
    /// A server event named like the state's `SchemaNameA.Item`, holding one.
    @Payload
    struct Item: ServerEventPayload {
        let inner: SchemaNameA.Item
    }

    /// A server input holding a `SchemaNameB.Item`, a type named like the state's.
    @Payload
    struct Holder: ServerInputPayload {
        let item: SchemaNameB.Item
    }
}

@StateNodeBuilder
struct SchemaNameItemsState: StateNodeProtocol {
    @Sync(.broadcast)
    var first: SchemaNameA.Item = SchemaNameA.Item()

    @Sync(.broadcast)
    var second: SchemaNameB.Item = SchemaNameB.Item()
}

@StateNodeBuilder
struct SchemaNameSpotsState: StateNodeProtocol {
    @Sync(.broadcast)
    var atomic: SchemaNameA.Spot = SchemaNameA.Spot()

    @Sync(.broadcast)
    var plain: SchemaNameB.Spot = SchemaNameB.Spot()
}

/// One type reached several ways: two fields, a map's values and an optional.
@StateNodeBuilder
struct SchemaNameReusedState: StateNodeProtocol {
    @Sync(.broadcast)
    var first: SchemaNameA.Item = SchemaNameA.Item()

    @Sync(.broadcast)
    var second: SchemaNameA.Item = SchemaNameA.Item()

    @Sync(.broadcast)
    var byName: [String: SchemaNameA.Item] = [:]

    @Sync(.broadcast)
    var maybe: SchemaNameA.Item? = nil
}

@StateNodeBuilder
struct SchemaNameFirstLandState: StateNodeProtocol {
    @Sync(.broadcast)
    var item: SchemaNameA.Item = SchemaNameA.Item()
}

@StateNodeBuilder
struct SchemaNameSecondLandState: StateNodeProtocol {
    @Sync(.broadcast)
    var item: SchemaNameB.Item = SchemaNameB.Item()
}

/// `SchemaNameA.Item` again, under another policy, so its definition's metadata differs.
@StateNodeBuilder
struct SchemaNameSameItemLandState: StateNodeProtocol {
    @Sync(.serverOnly)
    var kept: SchemaNameA.Item = SchemaNameA.Item()

    @Sync(.broadcast)
    var shown: [String: SchemaNameA.Item] = [:]
}

@StateNodeBuilder
struct SchemaNameStateDiffState: StateNodeProtocol {
    @Sync(.broadcast)
    var diff: SchemaNameA.StateDiff = SchemaNameA.StateDiff()
}

/// A plain `SchemaNameB.Bag` and an optional `SchemaNameA.Bag`, an inline collection.
@StateNodeBuilder
struct SchemaNameBagsState: StateNodeProtocol {
    @Sync(.broadcast)
    var plain: SchemaNameB.Bag = SchemaNameB.Bag()

    @Sync(.broadcast)
    var maybe: SchemaNameA.Bag? = nil
}

/// `SchemaNameA.Item`, and a set of `SchemaNameB.Item`s: only the fingerprint's walk converts a
/// set's element. Two types, one per order of the entry points (the verdict is cached per type).
@StateNodeBuilder
struct SchemaNameSetFirstState: StateNodeProtocol {
    @Sync(.broadcast)
    var item: SchemaNameA.Item = SchemaNameA.Item()

    @Sync(.broadcast)
    var others: Set<SchemaNameB.Item> = []
}

@StateNodeBuilder
struct SchemaNameSetSecondState: StateNodeProtocol {
    @Sync(.broadcast)
    var item: SchemaNameA.Item = SchemaNameA.Item()

    @Sync(.broadcast)
    var others: Set<SchemaNameB.Item> = []
}

@StateNodeBuilder
struct SchemaNameEventsState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

private let itemTypes = ["SwiftStateTreeTests.SchemaNameA.Item", "SwiftStateTreeTests.SchemaNameB.Item"]
private let itemCollision = SchemaTypeNameCollision(name: "Item", types: itemTypes)

private func collisions(_ body: () throws -> Void) -> [SchemaTypeNameCollision]? {
    do {
        try body()
        return nil
    } catch let error as SchemaTypeNameCollisionError {
        return error.collisions
    } catch {
        Issue.record("expected SchemaTypeNameCollisionError, got \(error)")
        return nil
    }
}

private func syncProblems<State: StateNodeProtocol>(_ definition: LandDefinition<State>) -> [SyncRegistrationError.Problem]? {
    do {
        try definition.validateForRegistration(context: .encodingIndependent)
        return nil
    } catch let error as LandRegistrationError {
        return error.sync?.problems
    } catch {
        Issue.record("expected LandRegistrationError, got \(error)")
        return nil
    }
}

private func land<State: StateNodeProtocol>(_ id: String, _ state: State.Type) -> LandDefinition<State> {
    Land(id, using: state) {
        Rules {}
    }
}

// MARK: - Tests

@Suite("Schema definitions: distinct types that share a name are refused (#602)")
struct SchemaTypeNameCollisionTests {
    @Test("A client event and a server event with one name: the schema is refused, naming both")
    func clientAndServerEventShareAName() throws {
        let definition = Land("schema-name-events", using: SchemaNameEventsState.self) {
            ClientEvents { Register(SchemaNameA.HitEvent.self) }
            ServerEvents { Register(SchemaNameB.HitEvent.self) }
            Rules {
                // Registered for the schema only; a registered client event needs a handler (#771).
                HandleEvent(SchemaNameA.HitEvent.self) { _, _, _ in }
            }
        }
        // They don't share a dispatch path, so registration takes them (#600).
        try definition.validateForRegistration(context: .encodingIndependent)

        let found = collisions { _ = try SchemaExtractor.extract(from: definition) }
        #expect(found == [SchemaTypeNameCollision(
            name: "HitEvent",
            types: ["SwiftStateTreeTests.SchemaNameA.HitEvent", "SwiftStateTreeTests.SchemaNameB.HitEvent"]
        )])
    }

    @Test("Two state types with one name: registration refuses the land, and so does the schema")
    func stateTypesShareAName() {
        let definition = land("schema-name-items", SchemaNameItemsState.self)
        #expect(syncProblems(definition) == [.typeNameCollision(itemCollision)])
        let error = #expect(throws: LandRegistrationError.self) { _ = try SchemaExtractor.extract(from: definition) }
        #expect(error?.sync?.problems == [.typeNameCollision(itemCollision)])
    }

    @Test("An atomic and a plain type with one name: the atomic layout isn't built from either")
    func atomicLayoutRefusesSharedName() {
        let found = collisions { _ = try AtomicLayoutTable.build(for: SchemaNameSpotsState.self) }
        #expect(found == [SchemaTypeNameCollision(
            name: "Spot",
            types: ["SwiftStateTreeTests.SchemaNameA.Spot", "SwiftStateTreeTests.SchemaNameB.Spot"]
        )])
        #expect(syncProblems(land("schema-name-spots", SchemaNameSpotsState.self)) == [.typeNameCollision(
            SchemaTypeNameCollision(
                name: "Spot",
                types: ["SwiftStateTreeTests.SchemaNameA.Spot", "SwiftStateTreeTests.SchemaNameB.Spot"]
            )
        )])
    }

    @Test("An optional inline collection and an object with one name: refused, not looked up as each other")
    func optionalCollectionSharesAName() {
        #expect(syncProblems(land("schema-name-bags", SchemaNameBagsState.self)) == [.typeNameCollision(
            SchemaTypeNameCollision(
                name: "Bag",
                types: ["SwiftStateTreeTests.SchemaNameA.Bag", "SwiftStateTreeTests.SchemaNameB.Bag"]
            )
        )])
    }

    @Test("A server event that replaces the state's definition of its name: the collision, not a false cycle, in one land and under SchemaGenCLI")
    func serverEventReplacesAStateDefinition() throws {
        let definition = Land("schema-name-event-item", using: SchemaNameFirstLandState.self) {
            ServerEvents { Register(SchemaNameC.Item.self) }
            Rules {}
        }
        try definition.validateForRegistration(context: .encodingIndependent)
        let expected = [SchemaTypeNameCollision(
            name: "Item", types: ["SwiftStateTreeTests.SchemaNameA.Item", "SwiftStateTreeTests.SchemaNameC.Item"]
        )]
        #expect(collisions { _ = try SchemaExtractor.extract(from: definition) } == expected)
        // Under SchemaGenCLI the land's own record is checked before its paths are flattened.
        #expect(collisions { _ = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(definition)]) } == expected)
    }

    @Test("A server input named like a state type, or holding one: the replay fingerprint is refused, not hashed")
    func serverInputsShareANameInTheFingerprint() {
        let named = Land("schema-name-input-item", using: SchemaNameFirstLandState.self) {
            Rules {
                HandleServerInput(SchemaNameD.Item.self) { _, _, _ in }
            }
        }
        let holder = Land("schema-name-input-holder", using: SchemaNameFirstLandState.self) {
            Rules {
                HandleServerInput(SchemaNameC.Holder.self) { _, _, _ in }
            }
        }
        #expect(collisions { _ = try ReevaluationSchemaFingerprint.compute(for: named) } == [SchemaTypeNameCollision(
            name: "Item", types: ["SwiftStateTreeTests.SchemaNameA.Item", "SwiftStateTreeTests.SchemaNameD.Item"]
        )])
        #expect(collisions { _ = try ReevaluationSchemaFingerprint.compute(for: holder) } == [itemCollision])
        // Registration for replay reports it as a registration problem, not a bare error.
        let error = #expect(throws: LandRegistrationError.self) {
            try holder.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(error?.typeNameCollisions == [itemCollision])
        #expect(error?.schemaFingerprint == nil)
    }

    @Test("A set's element is checked by the fingerprint, and registration's cached verdict doesn't depend on which ran first",
          arguments: [false, true])
    func setElementVerdictIsOrderIndependent(fingerprintFirst: Bool) throws {
        let setFirst = land("schema-name-set-first", SchemaNameSetFirstState.self)
        let setSecond = land("schema-name-set-second", SchemaNameSetSecondState.self)
        if fingerprintFirst {
            #expect(collisions { _ = try ReevaluationSchemaFingerprint.compute(for: setSecond) } == [itemCollision])
            try setSecond.validateForRegistration(context: .encodingIndependent)
        } else {
            try setFirst.validateForRegistration(context: .encodingIndependent)
            #expect(collisions { _ = try ReevaluationSchemaFingerprint.compute(for: setFirst) } == [itemCollision])
            try setFirst.validateForRegistration(context: .encodingIndependent)
        }
    }

    @Test("Two lands that each define a name with a different type: the merged schema is refused")
    func landsShareAName() throws {
        let first = AnyLandDefinition(land("schema-name-first", SchemaNameFirstLandState.self))
        let second = AnyLandDefinition(land("schema-name-second", SchemaNameSecondLandState.self))
        // Each alone has one `Item`.
        _ = try SchemaGenCLI.generateSchema(landDefinitions: [first])
        _ = try SchemaGenCLI.generateSchema(landDefinitions: [second])

        let found = collisions { _ = try SchemaGenCLI.generateSchema(landDefinitions: [first, second]) }
        #expect(found == [SchemaTypeNameCollision(name: "Item", types: itemTypes)])
    }

    @Test("A user type named StateDiff: the schema's diff placeholder would replace it, so it is refused")
    func stateDiffNameIsReserved() throws {
        let definition = land("schema-name-state-diff", SchemaNameStateDiffState.self)
        try definition.validateForRegistration(context: .encodingIndependent)
        let found = collisions { _ = try SchemaExtractor.extract(from: definition) }
        #expect(found == [SchemaTypeNameCollision(
            name: "StateDiff",
            types: ["SwiftStateTreeTests.SchemaNameA.StateDiff", "the schema's diff placeholder"]
        )])
        #expect(found?.first?.description
            == "StateDiff is reserved for the schema's diff placeholder; give SwiftStateTreeTests.SchemaNameA.StateDiff another name")
    }

    @Test("One type reached several ways, in one land or in two, is not a collision")
    func oneTypeIsNotACollision() throws {
        let reused = land("schema-name-reused", SchemaNameReusedState.self)
        try reused.validateForRegistration(context: .encodingIndependent)
        let schema = try SchemaExtractor.extract(from: reused)
        #expect(schema.defs["Item"] != nil, "\(schema.defs.keys.sorted())")
        _ = try AtomicLayoutTable.build(for: SchemaNameReusedState.self)

        _ = try SchemaGenCLI.generateSchema(landDefinitions: [
            AnyLandDefinition(land("schema-name-first", SchemaNameFirstLandState.self)),
            AnyLandDefinition(land("schema-name-same-item", SchemaNameSameItemLandState.self)),
            AnyLandDefinition(reused),
        ])
    }
}
