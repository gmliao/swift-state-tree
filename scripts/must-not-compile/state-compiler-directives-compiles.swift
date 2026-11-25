// expect: compiles
import SwiftStateTree

// `#warning` and `#error` parse as freestanding expansions but are compiler directives: the
// PlainData walk lets them through, so an `#error` in an inactive `#if` branch compiles. An
// active `#warning` is pinned by the macro tests, since this runner treats warnings as errors.
@StateNodeBuilder
struct DirectiveState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    #if false
    #error("unsupported platform")
    #endif

    init() {}
}

@PlainData
struct DirectiveValue: Sendable {
    var hp: Int = 0

    #if false
    #error("unsupported platform")
    #endif
}
