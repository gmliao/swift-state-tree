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
extension ValueCheckObject: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class the runtime walk must refuse (#464)


/// A plain struct that holds a class, behind a hand-written witness.
struct ValueCheckHolder: Sendable {
    var count = 0
    var object = ValueCheckObject()
}
extension ValueCheckHolder: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class in state for the runtime walk (#464), which keeps guarding hand-written witnesses

/// A reference type that converts itself: still a class.
final class ValueCheckConvertibleObject: SnapshotValueConvertible, @unchecked Sendable {
    func toSnapshotValue() throws -> SnapshotValue { .int(1) }
}
extension ValueCheckConvertibleObject: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class the runtime walk must refuse (#464)


/// A reference type with a full-state conversion of its own: still a class.
final class ValueCheckFullObject: FullSnapshotValueConvertible, @unchecked Sendable {
    func toFullSnapshotValue() throws -> SnapshotValue { .int(2) }
}

/// A hashable reference type, for dictionary keys and set elements.
final class ValueCheckKey: Hashable, @unchecked Sendable {
    static func == (lhs: ValueCheckKey, rhs: ValueCheckKey) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
extension ValueCheckKey: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class the runtime walk must refuse (#464)


enum ValueCheckChoice: Sendable {
    case none
    case object(ValueCheckObject)
}
extension ValueCheckChoice: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class in state for the runtime walk (#464), which keeps guarding hand-written witnesses

/// A plain struct whose tuple and enum payload hold a class.
struct ValueCheckShapes: Sendable {
    var pair: (Int, ValueCheckObject) = (1, ValueCheckObject())
    var choice: ValueCheckChoice = .object(ValueCheckObject())
    var unset: ValueCheckChoice = .none
}
extension ValueCheckShapes: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class in state for the runtime walk (#464), which keeps guarding hand-written witnesses

/// A struct that converts itself and holds a class: the conformance doesn't make it a value.
struct ValueCheckConvertibleHolder: SnapshotValueConvertible, Sendable {
    var count: Int = 0
    var object: ValueCheckObject = ValueCheckObject()
    func toSnapshotValue() throws -> SnapshotValue { .object(["count": .int(count)]) }
}
extension ValueCheckConvertibleHolder: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class in state for the runtime walk (#464), which keeps guarding hand-written witnesses

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

/// An existential type: only the value's dynamic type says whether it is a class. A
/// state field can't be one (Sync requires PlainData, scripts/must-not-compile/
/// state-existential-alias.swift), so it sits in a plain struct behind a hand-written witness.
protocol ValueCheckPayload: Sendable {}
extension Int: ValueCheckPayload {}
extension ValueCheckObject: ValueCheckPayload {}
extension ValueCheckConvertibleObject: ValueCheckPayload {}
extension ValueCheckFullObject: ValueCheckPayload {}
typealias ValueCheckAnyPayload = any ValueCheckPayload

struct ValueCheckExistentialBox: Sendable {
    var anything: ValueCheckAnyPayload = ValueCheckObject()
}
extension ValueCheckExistentialBox: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class in state for the runtime walk (#464), which keeps guarding hand-written witnesses

@StateNodeBuilder
struct ValueCheckExistentialRoot: StateNodeProtocol {
    @Sync(.broadcast) var box: ValueCheckExistentialBox = ValueCheckExistentialBox()
    init() {}
}

struct ValueCheckRuntimeBox: Sendable {
    var anything: ValueCheckAnyPayload = 0
    /// `(any P)?`: conversion gets the class boxed in an `Optional`.
    var maybe: ValueCheckAnyPayload? = nil
}
extension ValueCheckRuntimeBox: PlainData { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: a class in state for the runtime walk (#464), which keeps guarding hand-written witnesses

@StateNodeBuilder
struct ValueCheckRuntimeRoot: StateNodeProtocol {
    @Sync(.broadcast) var box: ValueCheckRuntimeBox = ValueCheckRuntimeBox()
    init() {}
}

@StateNodeBuilder
struct ValueCheckInternalRoot: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Internal var cache: [String: Int] = [:]
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

@PlainData
struct ValueCheckStats: Sendable {
    var wins: Int = 0
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

    @Test("An existential property whose default value is a class is refused")
    func existentialDefault() {
        #expect(valueViolations(ValueCheckExistentialRoot.self) == [
            .init(path: "ValueCheckExistentialRoot.box.anything", typeName: "ValueCheckObject"),
        ])
    }

    @Test("An @Internal field and a value-only state pass (an @Internal class doesn't compile: Internal requires PlainData)")
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
        root.box.anything = ValueCheckObject()
        let sent = #expect(throws: SyncError.self) { _ = try root.snapshot(for: nil, dirtyFields: nil) }
        let full = #expect(throws: SyncError.self) { _ = try root.fullStateSnapshot() }
        for error in [sent, full] {
            #expect(error.map { "\($0)" }?.contains("ValueCheckObject is a class; synced state must be value types") == true, "\(String(describing: error))")
        }

        // A class that converts itself is still refused, before its own conversion runs.
        root.box.anything = ValueCheckConvertibleObject()
        let convertedSent = #expect(throws: SyncError.self) { _ = try root.snapshot(for: nil, dirtyFields: nil) }
        let convertedFull = #expect(throws: SyncError.self) { _ = try root.fullStateSnapshot() }
        for error in [convertedSent, convertedFull] {
            #expect(error.map { "\($0)" }?.contains("ValueCheckConvertibleObject is a class") == true, "\(String(describing: error))")
        }

        // A class with a full-state conversion, refused by the state hash's conversion.
        root.box.anything = ValueCheckFullObject()
        let fullConverted = #expect(throws: SyncError.self) { _ = try root.fullStateSnapshot() }
        #expect(fullConverted.map { "\($0)" }?.contains("ValueCheckFullObject is a class") == true, "\(String(describing: fullConverted))")
    }

    @Test("A conforming class boxed in an Optional is refused when the state is converted")
    func runtimeClassInOptional() throws {
        var root = ValueCheckRuntimeRoot()
        root.box.maybe = 1
        _ = try root.snapshot(for: nil, dirtyFields: nil)
        _ = try root.fullStateSnapshot()
        root.box.maybe = ValueCheckConvertibleObject()
        let sent = #expect(throws: SyncError.self) { _ = try root.snapshot(for: nil, dirtyFields: nil) }
        let full = #expect(throws: SyncError.self) { _ = try root.fullStateSnapshot() }
        for error in [sent, full] {
            #expect(error.map { "\($0)" }?.contains("ValueCheckConvertibleObject is a class") == true, "\(String(describing: error))")
        }
        root.box.maybe = ValueCheckFullObject()
        let fullConverted = #expect(throws: SyncError.self) { _ = try root.fullStateSnapshot() }
        #expect(fullConverted.map { "\($0)" }?.contains("ValueCheckFullObject is a class") == true, "\(String(describing: fullConverted))")
    }

    @Test("The error names the field and the type, and says what to change")
    func errorMessage() {
        do {
            try SyncValueSemantics.validate(ValueCheckClassFieldRoot.self)
            Issue.record("expected a rejection")
        } catch {
            let text = "\(error)"
            #expect(text.contains("ValueCheckClassFieldRoot.inventory: ValueCheckObject is a class; synced state must be value types"))
            #expect(text.contains("land's services"))
        }
    }

    @Test("Schema extraction and SchemaGen refuse the land, with the class in LandRegistrationError.sync (#535)")
    func schemaEntryPoints() throws {
        let land = Land("value-check", using: ValueCheckClassFieldRoot.self) { Rules {} }
        var error = try #require(throws: LandRegistrationError.self) { _ = try SchemaExtractor.extract(from: land) }
        #expect(error.sync?.problems.contains(where: { if case .valueSemantics = $0 { true } else { false } }) == true)
        error = try #require(throws: LandRegistrationError.self) {
            _ = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(land)])
        }
        #expect(error.sync?.problems.contains(where: { if case .valueSemantics = $0 { true } else { false } }) == true)
    }
}
