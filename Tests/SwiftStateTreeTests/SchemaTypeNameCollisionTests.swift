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

    struct Item: Codable, Equatable, Sendable {
        var hp: Int = 0
    }

    /// Declared atomic: sent positionally as its leaves.
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
    struct StateDiff: Codable, Equatable, Sendable {
        var changed: Int = 0
    }
}

enum SchemaNameB {
    @Payload
    struct HitEvent: ServerEventPayload {
        let source: String
        let critical: Bool
    }

    struct Item: Codable, Equatable, Sendable {
        var name: String = ""
        var level: Int = 0
    }

    /// Not atomic, with other fields than `SchemaNameA.Spot`.
    struct Spot: Codable, Equatable, Sendable {
        var label: String = ""
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

@StateNodeBuilder
struct SchemaNameEventsState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

private let itemTypes = ["SwiftStateTreeTests.SchemaNameA.Item", "SwiftStateTreeTests.SchemaNameB.Item"]

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
            Rules {}
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
        let expected = SchemaTypeNameCollision(name: "Item", types: itemTypes)
        #expect(syncProblems(definition) == [.typeNameCollision(expected)])
        #expect(throws: LandRegistrationError.self) { _ = try SchemaExtractor.extract(from: definition) }
    }

    @Test("An atomic and a plain type with one name: the atomic layout isn't built from either")
    func atomicLayoutRefusesSharedName() {
        let found = collisions { _ = try AtomicLayoutTable.build(for: SchemaNameSpotsState.self) }
        #expect(found == [SchemaTypeNameCollision(
            name: "Spot",
            types: ["SwiftStateTreeTests.SchemaNameA.Spot", "SwiftStateTreeTests.SchemaNameB.Spot"]
        )])
        #expect(syncProblems(land("schema-name-spots", SchemaNameSpotsState.self))?.count == 1)
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
        #expect(found?.map(\.name) == ["StateDiff"])
        #expect(found?.first?.types.contains("SwiftStateTreeTests.SchemaNameA.StateDiff") == true)
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
