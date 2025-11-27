import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class LandMacroTests {
    private let landMacros: [String: Macro.Type] = [
        "Land": LandMacro.self
    ]

    private let eventMacros: [String: Macro.Type] = [
        "GenerateLandEventHandlers": GenerateLandEventHandlersMacro.self
    ]

    @Test("Land macro generates definition property")
    func testLandMacroExpansion() {
        assertMacroExpansion(
            """
            @Land(GameState.self, client: ClientEvents.self, server: ServerEvents.self, id: "demo-land")
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

                public static var definition: LandDefinition<GameState, ClientEvents, ServerEvents> {
                    Land("demo-land", using: GameState.self, clientEvents: ClientEvents.self, serverEvents: ServerEvents.self) {
                        Self.body
                    }
                }
            }
            """,
            macros: landMacros
        )
    }

    @Test("GenerateLandEventHandlers creates On functions")
    func testGenerateLandEventHandlersMacro() {
        assertMacroExpansion(
            """
            @GenerateLandEventHandlers
            enum ClientEvents: ClientEventPayload {
                case ready
                case chat(String)
            }
            """,
            expandedSource: """
            enum ClientEvents: ClientEventPayload {
                case ready
                case chat(String)
            }

            public func OnReady<State: StateNodeProtocol>(
                _ body: @escaping @Sendable (inout State, LandContext) async -> Void
            ) -> AnyClientEventHandler<State, ClientEvents> {
                On(ClientEvents.self) { state, event, ctx in
                    guard case .ready = event else {
                        return
                    }
                    await body(&state, ctx)
                }
            }

            public func OnChat<State: StateNodeProtocol>(
                _ body: @escaping @Sendable (inout State, String, LandContext) async -> Void
            ) -> AnyClientEventHandler<State, ClientEvents> {
                On(ClientEvents.self) { state, event, ctx in
                    guard case .chat(let value0) = event else {
                        return
                    }
                    await body(&state, value0, ctx)
                }
            }
            """,
            macros: eventMacros
        )
    }
}

