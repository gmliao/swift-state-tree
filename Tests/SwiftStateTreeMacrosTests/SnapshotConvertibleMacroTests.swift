// Tests/SwiftStateTreeMacrosTests/SnapshotConvertibleMacroTests.swift

import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

final class SnapshotConvertibleMacroTests {
    let testMacros: [String: Macro.Type] = [
        "SnapshotConvertible": SnapshotConvertibleMacro.self
    ]
    
    @Test("SnapshotConvertible macro generates toSnapshotValue method for basic types")
    func testSnapshotConvertibleMacro_BasicTypes() throws {
        expectMacroExpansion(
            """
            @SnapshotConvertible
            struct PlayerState: Codable {
                var name: String
                var hpCurrent: Int
                var hpMax: Int
            }
            """,
            expandedSource: """

            struct PlayerState: Codable {
                var name: String
                var hpCurrent: Int
                var hpMax: Int
            }

            extension PlayerState: SnapshotValueConvertible, FullSnapshotValueConvertible {
                public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    _ = try budget.enteringContainer()
                return .object([
                    "name": .string(self.name),
                    "hpCurrent": .int(self.hpCurrent),
                    "hpMax": .int(self.hpMax)
                ])
                }

                public func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "name": try SnapshotValue.makeFull(from: self.name as Any, budget: inner),
                    "hpCurrent": try SnapshotValue.makeFull(from: self.hpCurrent as Any, budget: inner),
                    "hpMax": try SnapshotValue.makeFull(from: self.hpMax as Any, budget: inner)
                ])
                }

                public func toSnapshotValue() throws -> SnapshotValue {
                    try toSnapshotValue(budget: NestingBudget())
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    try toFullSnapshotValue(budget: NestingBudget())
                }
            }

            extension PlayerState: SnapshotConvertibleStoredFields {
                public static var _snapshotStoredFields: [(name: String, type: Any.Type)] {
                    [
                    ("name", (String).self),
                    ("hpCurrent", (Int).self),
                    ("hpMax", (Int).self)
                ]
                }
            }

            extension PlayerState {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {
                    @available(*, deprecated, message: "the @PlainData checks; never called")
                    func check(_ value: inout Self) {
                        SwiftStateTurns.PlainDataCheck.field(value.name)
                        SwiftStateTurns.PlainDataCheck.field(value.hpCurrent)
                        SwiftStateTurns.PlainDataCheck.field(value.hpMax)
                    }
                }
            }

            extension PlayerState: SnapshotValueDecodable {
                public init(fromSnapshotValue value: SnapshotValue) throws {
                    guard case .object(let _dict) = value else {
                        throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                    }
                    self.init()
                    if let _v = _dict["name"] {
                        self.name = try _snapshotDecode(_v)
                    }
                    if let _v = _dict["hpCurrent"] {
                        self.hpCurrent = try _snapshotDecode(_v)
                    }
                    if let _v = _dict["hpMax"] {
                        self.hpMax = try _snapshotDecode(_v)
                    }
                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("SnapshotConvertible macro handles empty struct")
    func testSnapshotConvertibleMacro_EmptyStruct() throws {
        expectMacroExpansion(
            """
            @SnapshotConvertible
            struct EmptyState: Codable {
            }
            """,
            expandedSource: """

            struct EmptyState: Codable {
            }

            extension EmptyState: SnapshotValueConvertible, FullSnapshotValueConvertible {
                public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    _ = try budget.enteringContainer()
                    return .object([:])
                }

                public func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    _ = try budget.enteringContainer()
                return .object([:])
                }

                public func toSnapshotValue() throws -> SnapshotValue {
                    try toSnapshotValue(budget: NestingBudget())
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    try toFullSnapshotValue(budget: NestingBudget())
                }
            }

            extension EmptyState: SnapshotConvertibleStoredFields {
                public static var _snapshotStoredFields: [(name: String, type: Any.Type)] {
                    []
                }
            }

            extension EmptyState {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {

                }
            }

            extension EmptyState: SnapshotValueDecodable {
                public init(fromSnapshotValue value: SnapshotValue) throws {
                    guard case .object(let _dict) = value else {
                        throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                    }
                    self.init()

                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("SnapshotConvertible macro handles complex types")
    func testSnapshotConvertibleMacro_ComplexTypes() throws {
        expectMacroExpansion(
            """
            @SnapshotConvertible
            struct GameState: Codable {
                var players: [String: PlayerState]
                var round: Int
            }
            """,
            expandedSource: """

            struct GameState: Codable {
                var players: [String: PlayerState]
                var round: Int
            }

            extension GameState: SnapshotValueConvertible, FullSnapshotValueConvertible {
                public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "players": try SnapshotValue.make(from: self.players, budget: inner),
                    "round": .int(self.round)
                ])
                }

                public func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "players": try SnapshotValue.makeFull(from: self.players as Any, budget: inner),
                    "round": try SnapshotValue.makeFull(from: self.round as Any, budget: inner)
                ])
                }

                public func toSnapshotValue() throws -> SnapshotValue {
                    try toSnapshotValue(budget: NestingBudget())
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    try toFullSnapshotValue(budget: NestingBudget())
                }
            }

            extension GameState: SnapshotConvertibleStoredFields {
                public static var _snapshotStoredFields: [(name: String, type: Any.Type)] {
                    [
                    ("players", ([String: PlayerState]).self),
                    ("round", (Int).self)
                ]
                }
            }

            extension GameState {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {
                    @available(*, deprecated, message: "the @PlainData checks; never called")
                    func check(_ value: inout Self) {
                        SwiftStateTurns.PlainDataCheck.field(value.players)
                        SwiftStateTurns.PlainDataCheck.field(value.round)
                    }
                }
            }

            extension GameState: SnapshotValueDecodable {
                public init(fromSnapshotValue value: SnapshotValue) throws {
                    guard case .object(let _dict) = value else {
                        throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                    }
                    self.init()
                    if let _v = _dict["players"] {
                        self.players = try _snapshotDecode(_v)
                    }
                    if let _v = _dict["round"] {
                        self.round = try _snapshotDecode(_v)
                    }
                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("SnapshotConvertible macro spells an implicitly unwrapped optional as its optional type in the generated lists")
    func testSnapshotConvertibleMacro_ImplicitlyUnwrapped() throws {
        expectMacroExpansion(
            """
            @SnapshotConvertible
            struct Frozen {
                let count: Int!
            }
            """,
            expandedSource: """

            struct Frozen {
                let count: Int!
            }

            extension Frozen: SnapshotValueConvertible, FullSnapshotValueConvertible {
                public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "count": try SnapshotValue.make(from: self.count, budget: inner)
                ])
                }

                public func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "count": try SnapshotValue.makeFull(from: self.count as Any, budget: inner)
                ])
                }

                public func toSnapshotValue() throws -> SnapshotValue {
                    try toSnapshotValue(budget: NestingBudget())
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    try toFullSnapshotValue(budget: NestingBudget())
                }
            }

            extension Frozen: SnapshotConvertibleStoredFields {
                public static var _snapshotStoredFields: [(name: String, type: Any.Type)] {
                    [
                    ("count", (Int?).self)
                ]
                }
            }

            extension Frozen {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {
                    @available(*, deprecated, message: "the @PlainData checks; never called")
                    func check(_ value: inout Self) {
                        SwiftStateTurns.PlainDataCheck.field(value.count)
                    }
                }
            }

            extension Frozen: SnapshotFieldListProvider {
                public static var snapshotFieldMetadata: [FieldMetadata] {
                    [
                    FieldMetadata(name: "count", type: (Int?).self, policy: nil, nodeKind: SchemaHelper.determineNodeKind(from: (Int?).self), defaultValue: nil)
                ]
                }
            }
            """,
            macros: testMacros
        )
    }

    @Test("SnapshotConvertible macro handles optional types")
    func testSnapshotConvertibleMacro_OptionalTypes() throws {
        expectMacroExpansion(
            """
            @SnapshotConvertible
            struct OptionalState: Codable {
                var name: String?
                var score: Int
            }
            """,
            expandedSource: """

            struct OptionalState: Codable {
                var name: String?
                var score: Int
            }

            extension OptionalState: SnapshotValueConvertible, FullSnapshotValueConvertible {
                public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "name": try SnapshotValue.make(from: self.name, budget: inner),
                    "score": .int(self.score)
                ])
                }

                public func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "name": try SnapshotValue.makeFull(from: self.name as Any, budget: inner),
                    "score": try SnapshotValue.makeFull(from: self.score as Any, budget: inner)
                ])
                }

                public func toSnapshotValue() throws -> SnapshotValue {
                    try toSnapshotValue(budget: NestingBudget())
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    try toFullSnapshotValue(budget: NestingBudget())
                }
            }

            extension OptionalState: SnapshotConvertibleStoredFields {
                public static var _snapshotStoredFields: [(name: String, type: Any.Type)] {
                    [
                    ("name", (String?).self),
                    ("score", (Int).self)
                ]
                }
            }

            extension OptionalState {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {
                    @available(*, deprecated, message: "the @PlainData checks; never called")
                    func check(_ value: inout Self) {
                        SwiftStateTurns.PlainDataCheck.field(value.name)
                        SwiftStateTurns.PlainDataCheck.field(value.score)
                    }
                }
            }

            extension OptionalState: SnapshotValueDecodable {
                public init(fromSnapshotValue value: SnapshotValue) throws {
                    guard case .object(let _dict) = value else {
                        throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                    }
                    self.init()
                    if let _v = _dict["name"] {
                        self.name = try _snapshotDecode(_v)
                    }
                    if let _v = _dict["score"] {
                        self.score = try _snapshotDecode(_v)
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    @Test("SnapshotConvertible macro generates init(fromSnapshotValue:) for basic types")
    func generatesFromSnapshotValueInit() throws {
        expectMacroExpansion(
            """
            @SnapshotConvertible
            struct PlayerState: Codable {
                var name: String
                var hpCurrent: Int
                var hpMax: Int
            }
            """,
            expandedSource: """

            struct PlayerState: Codable {
                var name: String
                var hpCurrent: Int
                var hpMax: Int
            }

            extension PlayerState: SnapshotValueConvertible, FullSnapshotValueConvertible {
                public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    _ = try budget.enteringContainer()
                return .object([
                    "name": .string(self.name),
                    "hpCurrent": .int(self.hpCurrent),
                    "hpMax": .int(self.hpMax)
                ])
                }

                public func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    let inner = try budget.enteringContainer()
                return .object([
                    "name": try SnapshotValue.makeFull(from: self.name as Any, budget: inner),
                    "hpCurrent": try SnapshotValue.makeFull(from: self.hpCurrent as Any, budget: inner),
                    "hpMax": try SnapshotValue.makeFull(from: self.hpMax as Any, budget: inner)
                ])
                }

                public func toSnapshotValue() throws -> SnapshotValue {
                    try toSnapshotValue(budget: NestingBudget())
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    try toFullSnapshotValue(budget: NestingBudget())
                }
            }

            extension PlayerState: SnapshotConvertibleStoredFields {
                public static var _snapshotStoredFields: [(name: String, type: Any.Type)] {
                    [
                    ("name", (String).self),
                    ("hpCurrent", (Int).self),
                    ("hpMax", (Int).self)
                ]
                }
            }

            extension PlayerState {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {
                    @available(*, deprecated, message: "the @PlainData checks; never called")
                    func check(_ value: inout Self) {
                        SwiftStateTurns.PlainDataCheck.field(value.name)
                        SwiftStateTurns.PlainDataCheck.field(value.hpCurrent)
                        SwiftStateTurns.PlainDataCheck.field(value.hpMax)
                    }
                }
            }

            extension PlayerState: SnapshotValueDecodable {
                public init(fromSnapshotValue value: SnapshotValue) throws {
                    guard case .object(let _dict) = value else {
                        throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                    }
                    self.init()
                    if let _v = _dict["name"] {
                        self.name = try _snapshotDecode(_v)
                    }
                    if let _v = _dict["hpCurrent"] {
                        self.hpCurrent = try _snapshotDecode(_v)
                    }
                    if let _v = _dict["hpMax"] {
                        self.hpMax = try _snapshotDecode(_v)
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    @Test("SnapshotConvertible(atomic: true) rejects an optional leaf")
    func testSnapshotConvertibleMacro_AtomicRejectsOptionalLeaf() throws {
        let (expanded, context) = expandCollectingDiagnostics(
            """
            @SnapshotConvertible(atomic: true)
            struct Marker: Codable {
                var origin: IVec2?
            }
            """,
            macros: testMacros
        )
        #expect(expanded == """
            struct Marker: Codable {
                var origin: IVec2?
            }
            """)
        // The macro reports this error twice (#404): the diagnostic below, then the thrown error's
        // description at the attribute. This asserts today's behavior exactly; when #404 is
        // fixed the count drops to 1 and this test fails, so update it then.
        try #require(context.diagnostics.count == 2)
        expectDiagnostic(
            context.diagnostics[0],
            in: context,
            message: "@SnapshotConvertible(atomic: true): property 'origin' of type IVec2? can't be an atomic leaf; leaves are annotated scalars or atomic values, not optionals or collections",
            line: 1,
            column: 1
        )
        expectDiagnostic(
            context.diagnostics[1],
            in: context,
            messageStartingWith: "invalidAtomicProperty(",
            containing: ["name: \"origin\""],
            line: 1,
            column: 1
        )
    }
}
