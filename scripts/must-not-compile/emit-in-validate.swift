// expect-error: cannot convert value of type 'T?' to specified type '(any ServerEventPayload, EventTarget) -> Void'
// validate's context can't emit (#586): a refused input emits nothing.
// Only the resolver-output lookup answers the name, so its value can't be the member's type.
import SwiftStateTree

let emitInValidate = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self, validate: { (_: SnippetState, _: SnippetAction, ctx: ValidateContext) in
            let emit: (any ServerEventPayload, EventTarget) -> Void = ctx.emitEvent
            _ = emit
        }, apply: { (state: inout SnippetState, _: SnippetAction, _: LandContext) in
            SnippetResponse(total: state.total)
        })
    }
}
