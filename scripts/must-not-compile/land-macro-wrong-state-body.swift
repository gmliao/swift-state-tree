// expect-error: cannot convert value of type 'LandRules<OtherSnippetState, NoServices>' to expected argument type 'LandRules<SnippetState, NoServices>'
// #794: an `@Land` body under a hand-written builder for another State doesn't compile.
import SwiftStateTree

@StateNodeBuilder
struct OtherSnippetState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    init() {}
}

@Land(SnippetState.self)
struct SnippetWrongStateLand {
    @LandDSL<OtherSnippetState, NoServices>
    static var body: LandRules<OtherSnippetState, NoServices> {
        OnJoin { state, _ in state.count += 1 }
    }
}
