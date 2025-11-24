// Tests/SwiftStateTreeMacrosTests/StateMacroTests.swift

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class StateMacroTests {
    let testMacros: [String: Macro.Type] = [
        "State": StateMacro.self
    ]
    
    @Test("State macro validates struct conforms to StateProtocol")
    func testStateMacro_ValidConformance() throws {
        assertMacroExpansion(
            """
            @State
            struct PlayerState: StateProtocol {
                var name: String
                var hpCurrent: Int
            }
            """,
            expandedSource: """
            struct PlayerState: StateProtocol {
                var name: String
                var hpCurrent: Int
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("State macro rejects struct without StateProtocol conformance")
    func testStateMacro_RejectsMissingProtocol() throws {
        assertMacroExpansion(
            """
            @State
            struct PlayerState: Codable, Sendable {
                var name: String
            }
            """,
            expandedSource: """
            struct PlayerState: Codable, Sendable {
                var name: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Struct marked with @State must conform to StateProtocol",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }
    
    @Test("State macro rejects class declarations")
    func testStateMacro_RejectsClass() throws {
        assertMacroExpansion(
            """
            @State
            class PlayerState: StateProtocol {
                var name: String
            }
            """,
            expandedSource: """
            class PlayerState: StateProtocol {
                var name: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@State can only be applied to struct declarations",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }
}

