// expect-error: invalid conversion from throwing function
// OnFinalize can't throw (#593): the land is ending, so nothing would act on a refusal.
import SwiftStateTree

let throwInOnFinalize = Land("snippet", using: SnippetState.self) {
    Lifetime {
        OnFinalize { (state: inout SnippetState, _: LandContext) in
            state.total += 1
            if state.total > 4 { throw SnippetError() }
        }
    }
}
