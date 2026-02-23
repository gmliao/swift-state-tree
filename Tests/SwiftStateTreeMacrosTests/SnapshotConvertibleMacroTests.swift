// Tests/SwiftStateTreeMacrosTests/SnapshotConvertibleMacroTests.swift

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class SnapshotConvertibleMacroTests {
    let testMacros: [String: Macro.Type] = [
        "SnapshotConvertible": SnapshotConvertibleMacro.self
    ]
    
    @Test("SnapshotConvertible macro generates toSnapshotValue method for basic types")
    func testSnapshotConvertibleMacro_BasicTypes() throws {
        assertMacroExpansion(
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
            
            extension PlayerState: SnapshotValueConvertible {
                func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                        "name": .string(name),
                        "hpCurrent": .int(hpCurrent),
                        "hpMax": .int(hpMax)
                    ])
                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("SnapshotConvertible macro handles empty struct")
    func testSnapshotConvertibleMacro_EmptyStruct() throws {
        assertMacroExpansion(
            """
            @SnapshotConvertible
            struct EmptyState: Codable {
            }
            """,
            expandedSource: """
            struct EmptyState: Codable {
            }
            
            extension EmptyState: SnapshotValueConvertible {
                func toSnapshotValue() throws -> SnapshotValue {
                    return .object([:])
                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("SnapshotConvertible macro handles complex types")
    func testSnapshotConvertibleMacro_ComplexTypes() throws {
        assertMacroExpansion(
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
            
            extension GameState: SnapshotValueConvertible {
                func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                        "players": try SnapshotValue.make(from: players),
                        "round": .int(round)
                    ])
                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("SnapshotConvertible macro handles optional types")
    func testSnapshotConvertibleMacro_OptionalTypes() throws {
        assertMacroExpansion(
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

            extension OptionalState: SnapshotValueConvertible {
                func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                        "name": try SnapshotValue.make(from: name),
                        "score": .int(score)
                    ])
                }
            }
            """,
            macros: testMacros
        )
    }

    @Test("SnapshotConvertible macro generates init(fromSnapshotValue:) for basic types")
    func generatesFromSnapshotValueInit() throws {
        assertMacroExpansion(
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

            extension PlayerState: SnapshotValueConvertible {
                public func toSnapshotValue() throws -> SnapshotValue {
                    return .object([
                        "name": .string(name),
                        "hpCurrent": .int(hpCurrent),
                        "hpMax": .int(hpMax)
                    ])
                }
            }

            extension PlayerState: SnapshotValueDecodable {
                public init(fromSnapshotValue value: SnapshotValue) throws {
                    guard case .object(let _dict) = value else {
                        throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                    }
                    self.init()
                    if let _v = _dict["name"] { self.name = try _snapshotDecode(_v) }
                    if let _v = _dict["hpCurrent"] { self.hpCurrent = try _snapshotDecode(_v) }
                    if let _v = _dict["hpMax"] { self.hpMax = try _snapshotDecode(_v) }
                }
            }
            """,
            macros: testMacros
        )
    }
}

