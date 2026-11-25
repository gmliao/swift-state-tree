// expect-error: value of type 'ValidateContext' has no member 'serverInputs'
// validate's context can't submit server inputs (#586).
import SwiftStateTree

let serverInputsInValidate = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self, validate: { (_: SnippetState, _: SnippetAction, ctx: ValidateContext) in
            let submit: ServerInputSubmitter = ctx.serverInputs
            _ = submit
        }, apply: { (state: inout SnippetState, _: SnippetAction, _: LandContext) in
            SnippetResponse(total: state.total)
        })
    }
}
