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
                var gameName: String = ""
                
                @Sync(.serverOnly)
                var hiddenData: Int = 0
                
                @Internal
                var cache: [String: String] = [:]
            }
            """,
            expandedSource: """
            struct TestStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var gameName: String = ""
                
                @Sync(.serverOnly)
                var hiddenData: Int = 0
                
                @Internal
                var cache: [String: String] = [:]

                public var _$parentPath: String = ""

                public var _$patchRecorder: PatchRecorder? = nil
            
                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "gameName", policyType: .broadcast), SyncFieldInfo(name: "hiddenData", policyType: .serverOnly)]
                }
            
                public func validateSyncFields() -> Bool {
                    return true
                }
            }
            """,
            macros: testMacros
        )
    }

    #if SWIFT_STATE_TREE_ENABLE_SYNC_CONTAINER_GUARD
    @Test("StateNodeBuilder macro rejects dictionary on @Sync when guard is enabled")
    func testStateNodeBuilderMacroRejectsDictionarySyncField() {
        assertMacroExpansion(
            """
            @StateNodeBuilder
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: Int] = [:]
            }
            """,
            expandedSource: """
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: Int] = [:]
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Sync field 'players' uses untrackable container '[String: Int]'. Use ReactiveDictionary/ReactiveSet for incremental patch tracking.",
                    line: 4,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }

    @Test("StateNodeBuilder macro rejects set on @Sync when guard is enabled")
    func testStateNodeBuilderMacroRejectsSetSyncField() {
        assertMacroExpansion(
            """
            @StateNodeBuilder
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var ids: Set<String> = []
            }
            """,
            expandedSource: """
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var ids: Set<String> = []
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Sync field 'ids' uses untrackable container 'Set<String>'. Use ReactiveDictionary/ReactiveSet for incremental patch tracking.",
                    line: 4,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }
    #else
    @Test("StateNodeBuilder macro allows plain containers on @Sync when guard is disabled")
    func testStateNodeBuilderMacroAllowsPlainContainersWhenGuardDisabled() {
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

                public var _$parentPath: String = ""

                public var _$patchRecorder: PatchRecorder? = nil

                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "players", policyType: .broadcast), SyncFieldInfo(name: "hiddenData", policyType: .serverOnly)]
                }

                public func validateSyncFields() -> Bool {
                    return true
                }
            }
            """,
            macros: testMacros
        )
    }
    #endif

    @Test("StateNodeBuilder macro allows reactive containers on @Sync")
    func testStateNodeBuilderMacroAllowsReactiveContainers() {
        assertMacroExpansion(
            """
            @StateNodeBuilder
            struct ValidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: ReactiveDictionary<String, Int> = .init()

                @Sync(.broadcast)
                var ids: ReactiveSet<String> = .init()
            }
            """,
            expandedSource: """
            struct ValidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: ReactiveDictionary<String, Int> = .init()

                @Sync(.broadcast)
                var ids: ReactiveSet<String> = .init()

                public var _$parentPath: String = ""

                public var _$patchRecorder: PatchRecorder? = nil

                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "players", policyType: .broadcast), SyncFieldInfo(name: "ids", policyType: .broadcast)]
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
