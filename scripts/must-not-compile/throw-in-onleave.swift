// expect-error: invalid conversion from throwing function
// OnLeave can't throw (#586): a leave always happens.
import SwiftStateTree

let throwInOnLeave = Land("snippet", using: SnippetState.self) {
    Rules {
        OnLeave { (state: inout SnippetState, _: LandContext) in
            state.total -= 1
            if state.total < 0 { throw SnippetError() }
        }
    }
}
