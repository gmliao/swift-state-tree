// Tests/SwiftStateTreeTests/SyncValueSemanticsTests.swift
//
// #464: synced state is made of value types. Registration refuses a synced field that holds a
// class, at any depth; `SnapshotValue` refuses one that only appears at runtime. `@Internal`
// fields may hold a class.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// A reference type: a write through a copy reaches the original.
final class ValueCheckObject: @unchecked Sendable {
    var count = 0
}

/// A plain struct that holds a class.
struct ValueCheckHolder: Sendable {
    var count = 0
    var object = ValueCheckObject()
}

/// A reference type that converts itself: still a class.
final class ValueCheckConvertibleObject: SnapshotValueConvertible, @unchecked Sendable {
    func toSnapshotValue() throws -> SnapshotValue { .int(1) }
}

/// A hashable reference type, for dictionary keys and set elements.
final class ValueCheckKey: Hashable, @unchecked Sendable {
    static func == (lhs: ValueCheckKey, rhs: ValueCheckKey) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

enum ValueCheckChoice: Sendable {
    case none
    case object(ValueCheckObject)
}

/// A plain struct whose tuple and enum payload hold a class.
struct ValueCheckShapes: Sendable {
    var pair: (Int, ValueCheckObject) = (1, ValueCheckObject())
    var choice: ValueCheckChoice = .object(ValueCheckObject())
    var unset: ValueCheckChoice = .none
}

/// A struct that converts itself and holds a class: the conformance doesn't make it a value.
struct ValueCheckConvertibleHolder: SnapshotValueConvertible, Sendable {
    var count: Int = 0
    var object: ValueCheckObject = ValueCheckObject()
    func toSnapshotValue() throws -> SnapshotValue { .object(["count": .int(count)]) }
}

@StateNodeBuilder
struct ValueCheckClassFieldRoot: StateNodeProtocol {
    @Sync(.broadcast) var inventory: ValueCheckObject = ValueCheckObject()
    @Sync(.serverOnly) var hidden: ValueCheckObject = ValueCheckObject()
    @Sync(.broadcast) var convertible: ValueCheckConvertibleObject = ValueCheckConvertibleObject()
    init() {}
}

@StateNodeBuilder
struct ValueCheckShapesRoot: StateNodeProtocol {
    @Sync(.broadcast) var keyed: [ValueCheckKey: Int] = [:]
    @Sync(.broadcast) var tags: Set<ValueCheckKey> = []
    @Sync(.broadcast) var shapes: ValueCheckShapes = ValueCheckShapes()
    @Sync(.broadcast) var holder: ValueCheckConvertibleHolder = ValueCheckConvertibleHolder()
    init() {}
}

@StateNodeBuilder
struct ValueCheckContainersRoot: StateNodeProtocol {
    @Sync(.broadcast) var maybe: ValueCheckObject? = nil
    @Sync(.broadcast) var byKey: [String: ValueCheckObject] = [:]
    @Sync(.broadcast) var list: [ValueCheckObject] = []
    @Sync(.broadcast) var holder: ValueCheckHolder = ValueCheckHolder()
    init() {}
}

@StateNodeBuilder
struct ValueCheckNestedNode: StateNodeProtocol {
    @Sync(.broadcast) var object: ValueCheckObject = ValueCheckObject()
    init() {}
}

@StateNodeBuilder
struct ValueCheckNestedRoot: StateNodeProtocol {
    @Sync(.broadcast) var nodes: [String: ValueCheckNestedNode] = [:]
    init() {}
}

/// An existential field type: only the value's dynamic type says whether it is a class.
protocol ValueCheckPayload: Sendable {}
extension Int: ValueCheckPayload {}
extension ValueCheckObject: ValueCheckPayload {}
extension ValueCheckConvertibleObject: ValueCheckPayload {}
typealias ValueCheckAnyPayload = any ValueCheckPayload

@StateNodeBuilder
struct ValueCheckExistentialRoot: StateNodeProtocol {
    @Sync(.broadcast) var anything: ValueCheckAnyPayload = ValueCheckObject()
    init() {}
}

@StateNodeBuilder
struct ValueCheckRuntimeRoot: StateNodeProtocol {
    @Sync(.broadcast) var anything: ValueCheckAnyPayload = 0
    init() {}
}

@StateNodeBuilder
struct ValueCheckInternalRoot: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Internal var cache: ValueCheckObject = ValueCheckObject()
    init() {}
}

@StateNodeBuilder
struct ValueCheckValuesRoot: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var names: [String] = ["a"]
    @Sync(.broadcast) var byKey: [String: Int] = ["k": 1]
    @Sync(.broadcast) var node: ValueCheckValuesNode = ValueCheckValuesNode()
    @Sync(.serverOnly) var stats: ValueCheckStats = ValueCheckStats()
    init() {}
}

@StateNodeBuilder
struct ValueCheckValuesNode: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 10
    init() {}
}

struct ValueCheckStats: Sendable {
    var wins = 0
    var tags: [String] = []
}

private func valueViolations(_ type: any StateNodeProtocol.Type) -> [SyncValueSemanticsError.Violation]? {
    do {
        try SyncValueSemantics.validate(type)
        return nil
    } catch let error as SyncValueSemanticsError {
        return error.violations
    } catch {
        return []
    }
}

// MARK: - Tests

@Suite("Synced state is made of value types (#464)")
struct SyncValueSemanticsTests {
    @Test("A synced field whose type is a class is refused, server-only ones included")
    func classField() {
        #expect(valueViolations(ValueCheckClassFieldRoot.self) == [
            .init(path: "ValueCheckClassFieldRoot.inventory", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckClassFieldRoot.hidden", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckClassFieldRoot.convertible", typeName: "ValueCheckConvertibleObject"),
        ])
    }

    @Test("A class as a dictionary key, a set element, in a tuple, an enum payload or a converted struct is refused")
    func classInOtherShapes() {
        #expect(valueViolations(ValueCheckShapesRoot.self) == [
            .init(path: "ValueCheckShapesRoot.keyed[key]", typeName: "ValueCheckKey"),
            .init(path: "ValueCheckShapesRoot.tags[*]", typeName: "ValueCheckKey"),
            .init(path: "ValueCheckShapesRoot.shapes.pair.1", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckShapesRoot.shapes.choice.object", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckShapesRoot.holder.object", typeName: "ValueCheckObject"),
        ])
    }

    @Test("A class in an optional, a dictionary, an array, a plain struct or a nested node is refused")
    func classInContainers() {
        #expect(valueViolations(ValueCheckContainersRoot.self) == [
            .init(path: "ValueCheckContainersRoot.maybe", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckContainersRoot.byKey[*]", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckContainersRoot.list[*]", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckContainersRoot.holder.object", typeName: "ValueCheckObject"),
        ])
        #expect(valueViolations(ValueCheckNestedRoot.self) == [
            .init(path: "ValueCheckNestedRoot.nodes[*].object", typeName: "ValueCheckObject"),
        ])
    }

    @Test("An existential field whose default value is a class is refused")
    func existentialDefault() {
        #expect(valueViolations(ValueCheckExistentialRoot.self) == [
            .init(path: "ValueCheckExistentialRoot.anything", typeName: "ValueCheckObject"),
        ])
    }

    @Test("An @Internal field may hold a class, and a value-only state passes")
    func allowed() {
        #expect(valueViolations(ValueCheckInternalRoot.self) == nil)
        #expect(valueViolations(ValueCheckValuesRoot.self) == nil)
        #expect(valueViolations(ValueCheckRuntimeRoot.self) == nil)
    }

    @Test("A class that only appears at runtime is refused when the state is converted")
    func runtimeClass() throws {
        var root = ValueCheckRuntimeRoot()
        _ = try root.snapshot(for: nil, dirtyFields: nil)
        _ = try root.fullStateSnapshot()
        root.anything = ValueCheckObject()
        let sent = #expect(throws: SyncError.self) { _ = try root.snapshot(for: nil, dirtyFields: nil) }
        let full = #expect(throws: SyncError.self) { _ = try root.fullStateSnapshot() }
        for error in [sent, full] {
            #expect(error.map { "\($0)" }?.contains("ValueCheckObject is a class; synced state must be value types") == true, "\(String(describing: error))")
        }

        // A class that converts itself is still refused, before its own conversion runs.
        root.anything = ValueCheckConvertibleObject()
        let convertedSent = #expect(throws: SyncError.self) { _ = try root.snapshot(for: nil, dirtyFields: nil) }
        let convertedFull = #expect(throws: SyncError.self) { _ = try root.fullStateSnapshot() }
        for error in [convertedSent, convertedFull] {
            #expect(error.map { "\($0)" }?.contains("ValueCheckConvertibleObject is a class") == true, "\(String(describing: error))")
        }
    }

    @Test("The error names the field and the type, and says what to change")
    func errorMessage() {
        do {
            try SyncValueSemantics.validate(ValueCheckClassFieldRoot.self)
            Issue.record("expected a rejection")
        } catch {
            let text = "\(error)"
            #expect(text.contains("ValueCheckClassFieldRoot.inventory: ValueCheckObject is a class; synced state must be value types"))
            #expect(text.contains("@Internal"))
        }
    }

    @Test("Schema extraction and SchemaGen refuse the land")
    func schemaEntryPoints() {
        let land = Land("value-check", using: ValueCheckClassFieldRoot.self) { Rules {} }
        #expect(throws: SyncValueSemanticsError.self) { _ = try SchemaExtractor.extract(from: land) }
        #expect(throws: SyncValueSemanticsError.self) {
            _ = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(land)])
        }
    }
}
