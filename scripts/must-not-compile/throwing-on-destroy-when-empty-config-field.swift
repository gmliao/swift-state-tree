// expect-error: invalid conversion from throwing function
// LifetimeConfig.onDestroyWhenEmpty (the DSL's config) takes a closure that can't throw (#593):
// a throwing one would be the escape hatch #586 closed for actions.
import SwiftStateTree

func throwing_onDestroyWhenEmpty_Config() -> LifetimeConfig<SnippetState> {
    var config = LifetimeConfig<SnippetState>()
    config.onDestroyWhenEmpty = { (state: inout SnippetState, _: LandContext) in
        state.total = 1
        if state.total > 0 { throw SnippetError() }
    }
    return config
}
