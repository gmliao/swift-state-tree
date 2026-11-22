// expect-error: invalid conversion from throwing function
// LifetimeConfig.onFinalize (the DSL's config) takes a closure that can't throw (#593):
// a throwing one would be the escape hatch #586 closed for actions.
import SwiftStateTree

func throwing_onFinalize_Config() -> LifetimeConfig<SnippetState> {
    var config = LifetimeConfig<SnippetState>()
    config.onFinalize = { (state: inout SnippetState, _: LandContext) in
        state.total = 1
        if state.total > 0 { throw SnippetError() }
    }
    return config
}
