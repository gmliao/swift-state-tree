// expect-error: invalid conversion from throwing function
// LifetimeHandlers.onFinalize (a hand-built definition) takes a closure that can't throw (#593):
// a throwing one would be the escape hatch #586 closed for actions.
import SwiftStateTree

func throwing_onFinalize_Handlers() -> LifetimeHandlers<SnippetState> {
    var handlers = LifetimeHandlers<SnippetState>()
    handlers.onFinalize = { (state: inout SnippetState, _: LandContext) in
        state.total = 1
        if state.total > 0 { throw SnippetError() }
    }
    return handlers
}
