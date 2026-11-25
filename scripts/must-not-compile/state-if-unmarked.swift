// expect-error: must be marked with @Sync or @Internal
import SwiftStateTree

// An unmarked stored property inside `#if` is refused, as one outside `#if` is.
@StateNodeBuilder
struct FlagState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    #if swift(>=5.0)
    var debugCount: Int = 0
    #endif

    init() {}
}
