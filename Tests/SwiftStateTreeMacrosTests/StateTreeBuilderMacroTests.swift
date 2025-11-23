// Tests/SwiftStateTreeMacrosTests/StateTreeBuilderMacroTests.swift

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class StateTreeBuilderMacroTests {
    let testMacros: [String: Macro.Type] = [
        "StateTreeBuilder": StateTreeBuilderMacro.self
    ]
    
    @Test("StateTreeBuilder macro generates getSyncFields and validateSyncFields")
    func testStateTreeBuilderMacro() throws {
        assertMacroExpansion(
            """
            @StateTreeBuilder
            struct TestStateTree: StateTreeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                @Sync(.serverOnly)
                var hiddenData: Int = 0
                
                @Internal
                var cache: [String: String] = [:]
            }
            """,
            expandedSource: """
            struct TestStateTree: StateTreeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                @Sync(.serverOnly)
                var hiddenData: Int = 0
                
                @Internal
                var cache: [String: String] = [:]
            
                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "players", policyType: "broadcast"), SyncFieldInfo(name: "hiddenData", policyType: "serverOnly")]
                }
            
                public func validateSyncFields() -> Bool {
                    return true
                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("StateTreeBuilder macro rejects unmarked stored properties")
    func testStateTreeBuilderMacroRejectsUnmarkedProperties() {
        assertMacroExpansion(
            """
            @StateTreeBuilder
            struct InvalidStateTree: StateTreeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                var unmarkedProperty: Int = 0
            }
            """,
            expandedSource: """
            struct InvalidStateTree: StateTreeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                var unmarkedProperty: Int = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Stored property 'unmarkedProperty' in StateTree must be marked with @Sync or @Internal",
                    line: 6,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }
}

