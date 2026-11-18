// expect-error: invalid conversion from throwing function
// The single-closure HandleServerInput can't throw (#586).
import SwiftStateTree

let throwInSingleServerInput = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleServerInput(SnippetInput.self) { (state: inout SnippetState, input: SnippetInput, _: LandContext) in
            state.total += input.amount
            if input.amount < 0 { throw SnippetError() }
        }
    }
}
