// expect-error: invalid conversion from throwing function
// OnJoin can't throw (#586): whether a player may join is CanJoin's decision.
import SwiftStateTree

let throwInOnJoin = Land("snippet", using: SnippetState.self) {
    Rules {
        OnJoin { (state: inout SnippetState, _: LandContext) in
            state.total += 1
            if state.total > 4 { throw SnippetError() }
        }
    }
}
