// expect-error: cannot convert value of type 'T?' to specified type 'ServerInputSubmitter'
// validate's context can't submit server inputs (#586).
// Only the resolver-output lookup answers the name, so its value can't be the member's type.
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
