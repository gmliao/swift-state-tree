// expect-error: cannot convert value of type 'T?' to specified type 'DeterministicRngService'
// validate's context has no random source (#586): replay reruns validate.
// Only the resolver-output lookup answers the name, so its value can't be the member's type.
import SwiftStateTree

let randomInValidate = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self, validate: { (_: SnippetState, _: SnippetAction, ctx: ValidateContext) in
            let rng: DeterministicRngService = ctx.random
            _ = rng
        }, apply: { (state: inout SnippetState, _: SnippetAction, _: LandContext) in
            SnippetResponse(total: state.total)
        })
    }
}
