// expect-error: 'state' is a 'let' constant
// validate gets the state as a constant: it can't write (#586).
import SwiftStateTree

let writeInValidate = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self, validate: { (state: SnippetState, action: SnippetAction, _: ValidateContext) in
            state.total += action.amount
        }, apply: { (state: inout SnippetState, _: SnippetAction, _: LandContext) in
            SnippetResponse(total: state.total)
        })
    }
}
