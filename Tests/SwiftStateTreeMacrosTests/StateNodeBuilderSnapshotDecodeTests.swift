// Tests/SwiftStateTreeMacrosTests/StateNodeBuilderSnapshotDecodeTests.swift
// Verifies @StateNodeBuilder generates init(fromBroadcastSnapshot:) conformance.

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class StateNodeBuilderSnapshotDecodeTests {
    let testMacros: [String: Macro.Type] = [
        "StateNodeBuilder": StateNodeBuilderMacro.self
    ]

    @Test("StateNodeBuilder generates StateFromSnapshotDecodable extension")
    func generatesFromBroadcastSnapshotInit() throws {
        assertMacroExpansion(
            """
            @StateNodeBuilder
            struct SimpleState: StateNodeProtocol {
                @Sync(.broadcast)
                var score: Int = 0
                @Sync(.broadcast)
                var name: String = ""
                @Sync(.serverOnly)
                var internal_counter: Int = 0
            }
            """,
            expandedSource: """
            struct SimpleState: StateNodeProtocol {
                @Sync(.broadcast)
                var score: Int = 0
                @Sync(.broadcast)
                var name: String = ""
                @Sync(.serverOnly)
                var internal_counter: Int = 0
            }

            extension SimpleState: StateFromSnapshotDecodable {
                public init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
                    self.init()
                    if let _v = snapshot.values["score"] { self._score.wrappedValue = try _snapshotDecode(_v) }
                    if let _v = snapshot.values["name"] { self._name.wrappedValue = try _snapshotDecode(_v) }
                }
            }
            """,
            macros: testMacros
        )
    }
}
