// expect-error: invalid conversion from throwing function
// The single-closure OnInitialize can't throw (#593): a refusal belongs in validate.
import SwiftStateTree

let throwInSingleOnInitialize = Land("snippet", using: SnippetState.self) {
    Lifetime {
        OnInitialize { (state: inout SnippetState, _: LandContext) in
            state.total = 1
            if state.total > 0 { throw SnippetError() }
        }
    }
}
