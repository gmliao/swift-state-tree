// expect-error: cannot assign to property: 'amount' is a 'let' constant
// #771: an unannotated action closure gets the real types, so assigning to the action's `let`
// field is the compiler's usual error, not a type-inference failure.
import SwiftStateTree

let letActionField = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self) { state, action, _ in
            action.amount = 1
            return SnippetResponse(total: state.total)
        }
    }
}
