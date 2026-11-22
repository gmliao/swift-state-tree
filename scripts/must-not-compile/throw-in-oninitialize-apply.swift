// expect-error: invalid conversion from throwing function
// OnInitialize's apply can't throw (#593): a refusal belongs in validate, before anything is written.
import SwiftStateTree

let throwInOnInitializeApply = Land("snippet", using: SnippetState.self) {
    Lifetime {
        OnInitialize(validate: { (_: SnippetState, _: ValidateContext) in
        }, apply: { (state: inout SnippetState, _: LandContext) in
            state.total = 1
            if state.total > 0 { throw SnippetError() }
        })
    }
}
