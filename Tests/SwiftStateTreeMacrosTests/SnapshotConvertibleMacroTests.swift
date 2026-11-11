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
                public func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "name": .string(name),
                    "hpCurrent": .int(hpCurrent),
                    "hpMax": .int(hpMax)
                ])
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "name": try SnapshotValue.makeFull(from: self.name as Any),
                    "hpCurrent": try SnapshotValue.makeFull(from: self.hpCurrent as Any),
                    "hpMax": try SnapshotValue.makeFull(from: self.hpMax as Any)
                ])
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
                public func toSnapshotValue() throws -> SnapshotValue {
                    return .object([:])
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    return .object([:])
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
                public func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "players": try SnapshotValue.make(from: players),
                    "round": .int(round)
                ])
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "players": try SnapshotValue.makeFull(from: self.players as Any),
                    "round": try SnapshotValue.makeFull(from: self.round as Any)
                ])
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
                public func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "name": try SnapshotValue.make(from: name),
                    "score": .int(score)
                ])
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "name": try SnapshotValue.makeFull(from: self.name as Any),
                    "score": try SnapshotValue.makeFull(from: self.score as Any)
                ])
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
                public func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "name": .string(name),
                    "hpCurrent": .int(hpCurrent),
                    "hpMax": .int(hpMax)
                ])
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    return .object([
                    "name": try SnapshotValue.makeFull(from: self.name as Any),
                    "hpCurrent": try SnapshotValue.makeFull(from: self.hpCurrent as Any),
                    "hpMax": try SnapshotValue.makeFull(from: self.hpMax as Any)
                ])
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
