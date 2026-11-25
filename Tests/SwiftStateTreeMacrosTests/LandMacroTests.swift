import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

final class LandMacroTests {
    private let landMacros: [String: Macro.Type] = [
        "Land": LandMacro.self
    ]


    @Test("Land macro generates definition property and puts body under the land's builder")
    func testLandMacroExpansion() {
        expectMacroExpansion(
            """
            @Land(GameState.self, id: "demo-land")
            struct DemoLand {
                static var body: LandRules<GameState, NoServices> {
                    AccessControl { }
                }
            }
            """,
            expandedSource: """
            struct DemoLand {
                @LandDSL<GameState, NoServices>
                static var body: LandRules<GameState, NoServices> {
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

    @Test("A body that carries an attribute is left as written, and no other member gets one")
    func handWrittenBuilderAttributeIsKept() {
        expectMacroExpansion(
            """
            @Land(GameState.self, id: "demo-land")
            struct DemoLand {
                static let tag = "demo"
                @GameDSL
                static var body: LandRules<GameState, NoServices> {
                    AccessControl { }
                }
            }
            """,
            expandedSource: """
            struct DemoLand {
                static let tag = "demo"
                @GameDSL
                static var body: LandRules<GameState, NoServices> {
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

    @Test("@available alone doesn't opt a body out; a stored body gets no builder attribute")
    func availabilityAndStoredBodies() {
        expectMacroExpansion(
            """
            @Land(GameState.self, id: "available-land")
            struct AvailableLand {
                @available(*, deprecated)
                static var body: LandRules<GameState, NoServices> {
                    AccessControl { }
                }
            }
            """,
            expandedSource: """
            struct AvailableLand {
                @available(*, deprecated)
                @LandDSL<GameState, NoServices>
                static var body: LandRules<GameState, NoServices> {
                    AccessControl { }
                }

                public static var definition: LandDefinition<GameState> {
                    Land("available-land", using: GameState.self) {
                        Self.body
                    }
                }
            }
            """,
            macros: landMacros
        )
        expectMacroExpansion(
            """
            @Land(GameState.self, id: "stored-land")
            struct StoredLand {
                static let body: LandRules<GameState, NoServices> = Rules {}
            }
            """,
            expandedSource: """
            struct StoredLand {
                static let body: LandRules<GameState, NoServices> = Rules {}

                public static var definition: LandDefinition<GameState> {
                    Land("stored-land", using: GameState.self) {
                        Self.body
                    }
                }
            }
            """,
            macros: landMacros
        )
    }

    @Test("With services:, definition is the typed land and body is under the land's services (#769)")
    func servicesParameter() {
        expectMacroExpansion(
            """
            @Land(CartState.self, id: "cart", services: AppServices.self)
            struct CartLand {
                static var body: LandRules<CartState, AppServices> {
                    AccessControl { }
                }
            }
            """,
            expandedSource: """
            struct CartLand {
                @LandDSL<CartState, AppServices>
                static var body: LandRules<CartState, AppServices> {
                    AccessControl { }
                }

                public static var definition: TypedLand<CartState, AppServices> {
                    Land("cart", using: CartState.self, services: AppServices.self) {
                        Self.body
                    }
                }
            }
            """,
            macros: landMacros
        )
    }
}
