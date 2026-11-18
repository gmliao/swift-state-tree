// expect-error: invalid conversion from throwing function
// The single-closure HandleEvent can't throw (#586).
import SwiftStateTree

let throwInSingleEvent = Land("snippet", using: SnippetState.self) {
    ClientEvents { Register(SnippetEvent.self) }
    Rules {
        HandleEvent(SnippetEvent.self) { (state: inout SnippetState, event: SnippetEvent, _: LandContext) in
            state.total += event.amount
            if event.amount < 0 { throw SnippetError() }
        }
    }
}
