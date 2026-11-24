// expect-error: cannot convert value of type 'LandRules<OtherSnippetState, NoServices>' to expected argument type 'LandRules<SnippetState, NoServices>'
// #794: a helper built for another State doesn't splice into a land; its nodes would be dropped.
import SwiftStateTree

@StateNodeBuilder
struct OtherSnippetState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    init() {}
}

@LandDSL<OtherSnippetState, NoServices>
func otherRules() -> LandRules<OtherSnippetState, NoServices> {
    OnJoin { state, _ in state.count += 1 }
}

let land = Land("snippet", using: SnippetState.self) {
    otherRules()
}
