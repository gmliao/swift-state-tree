// expect-error: invalid conversion from throwing function
// The single-closure HandleAction can't throw (#586).
import SwiftStateTree

let throwInSingleAction = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self) { (state: inout SnippetState, action: SnippetAction, _: LandContext) in
            state.total += action.amount
            if state.total > 10 { throw SnippetError() }
            return SnippetResponse(total: state.total)
        }
    }
}
