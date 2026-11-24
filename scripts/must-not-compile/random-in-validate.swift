// expect-error: value of type 'ValidateContext' has no member 'random'
// validate's context has no random source (#586): replay reruns validate.
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
