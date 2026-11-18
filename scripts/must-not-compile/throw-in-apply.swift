// expect-error: invalid conversion from throwing function
// apply can't throw (#586): a refusal belongs in validate, before anything is written.
import SwiftStateTree

let throwInApply = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self, validate: { (_: SnippetState, _: SnippetAction, _: ValidateContext) in
        }, apply: { (state: inout SnippetState, action: SnippetAction, _: LandContext) in
            state.total += action.amount
            if state.total > 10 { throw SnippetError() }
            return SnippetResponse(total: state.total)
        })
    }
}
