import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class LandMacroTests {
    private let landMacros: [String: Macro.Type] = [
        "Land": LandMacro.self
    ]


    @Test("Land macro generates definition property")
    func testLandMacroExpansion() {
        assertMacroExpansion(
            """
            @Land(GameState.self, id: "demo-land")
            struct DemoLand {
                static var body: some LandDSL {
                    AccessControl { }
                }
            }
            """,
            expandedSource: """
            struct DemoLand {
                static var body: some LandDSL {
                    AccessControl { }
                }

                public static var definition: LandDefinition<GameState> {
                    Land("demo-land", using: GameState.self) {
                        Self.body
                    }
                }
            }
            """,
            macros: landMacros
        )
    }

}
