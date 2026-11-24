// expect: compiles
// #771 D-Q5: `@Land` used for real. The macro puts `body` under the land's builder, so its
// closures infer their types as in `Land(_:using:)`; a hand-written attribute, or an alias of
// the builder, is left as written and infers the same types.
import SwiftStateTree

@Land(SnippetState.self)
struct SnippetMacroLand {
    static var body: [LandNode] {
        Rules {
            OnJoin { state, _ in state.total += 1 }
            HandleAction(SnippetAction.self) { state, action, _ in
                state.total += action.amount
                return SnippetResponse(total: state.total)
            }
        }
    }
}

@Land(SnippetState.self, id: "snippet-macro-hand")
struct SnippetMacroHandLand {
    @LandDSL<SnippetState, NoServices>
    static var body: [LandNode] {
        Rules {
            OnJoin { state, _ in state.total += 1 }
            HandleAction(SnippetAction.self) { state, action, _ in
                state.total += action.amount
                return SnippetResponse(total: state.total)
            }
        }
    }
}

typealias SnippetDSL = LandDSL<SnippetState, NoServices>

@Land(SnippetState.self, id: "snippet-macro-alias")
struct SnippetMacroAliasLand {
    @SnippetDSL
    static var body: [LandNode] {
        Rules {
            OnJoin { state, _ in state.total += 1 }
        }
    }
}

/// A helper under the builder, spliced into a land and into a Rules (D-Q3, D-Q5).
@LandDSL<SnippetState, NoServices>
func snippetJoinRules() -> [LandNode] {
    OnJoin { state, _ in state.total += 1 }
}

let snippetMacroDefinitions = [SnippetMacroLand.definition, SnippetMacroHandLand.definition, SnippetMacroAliasLand.definition]
let snippetHelperLand = Land("snippet-helper", using: SnippetState.self) {
    snippetJoinRules()
    Rules { snippetJoinRules() }
}
