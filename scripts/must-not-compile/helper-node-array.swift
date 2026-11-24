// expect-error: 'buildExpression' is unavailable: a helper or @Land body returns LandRules<State, Services>, so its State and Services are checked
// #794: an array of nodes has lost its State, so a helper returning `[LandNode]` isn't spliced.
import SwiftStateTree

@LandDSL<SnippetState, NoServices>
func arrayRules() -> [LandNode] {
    OnJoin { state, _ in state.total += 1 }
}

let land = Land("snippet", using: SnippetState.self) {
    arrayRules()
}
