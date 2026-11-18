// expect-error: invalid conversion from throwing function
// A server input's apply can't throw (#586).
import SwiftStateTree

let throwInServerInputApply = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleServerInput(SnippetInput.self, validate: { (_: SnippetState, _: SnippetInput, _: ValidateContext) in
        }, apply: { (state: inout SnippetState, input: SnippetInput, _: LandContext) in
            state.total += input.amount
            if state.total > 10 { throw SnippetError() }
        })
    }
}
