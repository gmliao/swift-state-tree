// expect-error: cannot convert value of type 'LandRules<SnippetState, NoServices>' to expected argument type 'LandRules<SnippetState, SnippetServices>'
// #794: a helper's Services are checked too; one for any services is generic over them.
import SwiftStateTree

struct SnippetServices: Sendable {}

@LandDSL<SnippetState, NoServices>
func plainRules() -> LandRules<SnippetState, NoServices> {
    OnJoin { state, _ in state.total += 1 }
}

let land = Land("snippet", using: SnippetState.self, services: SnippetServices.self) {
    plainRules()
}
