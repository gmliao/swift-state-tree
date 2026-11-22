// expect-error: invalid conversion from throwing function
// LifetimeConfig.onInitialize (the DSL's config) holds an InitializeHandler, which has no
// public init that takes a throwing body (#593).
import SwiftStateTree

func throwingInitializeConfig() -> LifetimeConfig<SnippetState> {
    var config = LifetimeConfig<SnippetState>()
    config.onInitialize = InitializeHandler { (state: inout SnippetState, _: LandContext) in
        state.total = 1
        if state.total > 0 { throw SnippetError() }
    }
    return config
}
