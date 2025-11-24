// Tests/SwiftStateTreeMacrosTests/StateNodeBuilderMacroTests.swift

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class StateNodeBuilderMacroTests {
    let testMacros: [String: Macro.Type] = [
        "StateNodeBuilder": StateNodeBuilderMacro.self
    ]
    
    @Test("StateNodeBuilder macro generates getSyncFields and validateSyncFields")
    func testStateNodeBuilderMacro() throws {
        assertMacroExpansion(
            """
            @StateNodeBuilder
            struct TestStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                @Sync(.serverOnly)
                var hiddenData: Int = 0
                
                @Internal
                var cache: [String: String] = [:]
            }
            """,
            expandedSource: """
            struct TestStateNode: StateNodeProtocol {
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
    
    @Test("StateNodeBuilder macro rejects unmarked stored properties")
    func testStateNodeBuilderMacroRejectsUnmarkedProperties() {
        assertMacroExpansion(
            """
            @StateNodeBuilder
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                var unmarkedProperty: Int = 0
            }
            """,
            expandedSource: """
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                var unmarkedProperty: Int = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Stored property 'unmarkedProperty' in StateNode must be marked with @Sync or @Internal",
                    line: 6,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }
}

