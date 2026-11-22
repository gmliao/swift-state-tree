// expect-error: invalid conversion from throwing function
// InitializeHandler has no public init that takes a throwing body (#593): a hand-built
// definition can't put one in `onInitialize`.
import SwiftStateTree

func throwingInitializeHandler() -> LifetimeHandlers<SnippetState> {
    var handlers = LifetimeHandlers<SnippetState>()
    handlers.onInitialize = InitializeHandler { (state: inout SnippetState, _: LandContext) in
        state.total = 1
        if state.total > 0 { throw SnippetError() }
    }
    return handlers
}
