// expect-error: to expected argument type 'OnJoinNode<SnippetState>'
// #771: a node built for another State, placed at a land's top level, is refused too.
import SwiftStateTree

@StateNodeBuilder
struct SnippetTopOtherState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    init() {}
}

let otherStateJoin = OnJoin { (state: inout SnippetTopOtherState, _: LandContext) in state.count += 1 }

let wrongStateTopLevel = Land("snippet", using: SnippetState.self) {
    otherStateJoin
}
