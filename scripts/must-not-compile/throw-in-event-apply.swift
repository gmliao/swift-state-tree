// expect-error: invalid conversion from throwing function
// An event's apply can't throw (#586).
import SwiftStateTree

let throwInEventApply = Land("snippet", using: SnippetState.self) {
    ClientEvents { Register(SnippetEvent.self) }
    Rules {
        HandleEvent(SnippetEvent.self, validate: { (_: SnippetState, _: SnippetEvent, _: ValidateContext) in
        }, apply: { (state: inout SnippetState, event: SnippetEvent, _: LandContext) in
            state.total += event.amount
            if state.total > 10 { throw SnippetError() }
        })
    }
}
