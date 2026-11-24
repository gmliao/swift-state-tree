// expect-error: value of type 'ValidateContext' has no member 'emitEvent'
// validate's context can't emit (#586): a refused input emits nothing.
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
