// expect-error: to expected argument type 'OnJoinNode<SnippetState>'
// #771: a node for another State inside a land's Rules is refused where it is written, instead
// of being dropped silently by the land's builder.
import SwiftStateTree

@StateNodeBuilder
struct SnippetOtherState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    init() {}
}

let wrongStateNode = Land("snippet", using: SnippetState.self) {
    Rules {
        OnJoin { (state: inout SnippetOtherState, _: LandContext) in state.count += 1 }
    }
}
