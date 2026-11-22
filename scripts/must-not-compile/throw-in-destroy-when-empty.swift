// expect-error: invalid conversion from throwing function
// DestroyWhenEmpty's handler can't throw (#593), as OnFinalize's body can't.
import SwiftStateTree

let throwInDestroyWhenEmpty = Land("snippet", using: SnippetState.self) {
    Lifetime {
        DestroyWhenEmpty(after: .seconds(1)) { (state: inout SnippetState, _: LandContext) in
            state.total += 1
            if state.total > 4 { throw SnippetError() }
        }
    }
}
