// expect: compiles
// The control: the two-stage forms and a non-throwing single closure typecheck, so a failure
// in the other snippets comes from what they test, not from the setup.
import SwiftStateTree

let compilesLand = Land("snippet", using: SnippetState.self) {
    ClientEvents { Register(SnippetEvent.self) }
    Rules {
        OnJoin { (state: inout SnippetState, _: LandContext) in state.total += 1 }
        HandleAction(SnippetAction.self, validate: { (state: SnippetState, action: SnippetAction, _: ValidateContext) -> Int in
            guard action.amount > 0 else { throw SnippetError() }
            return state.total + action.amount
        }, apply: { (state: inout SnippetState, _: SnippetAction, total: Int, _: LandContext) in
            state.total = total
            return SnippetResponse(total: total)
        })
        HandleEvent(SnippetEvent.self) { (state: inout SnippetState, event: SnippetEvent, _: LandContext) in
            state.total += event.amount
        }
    }
}
