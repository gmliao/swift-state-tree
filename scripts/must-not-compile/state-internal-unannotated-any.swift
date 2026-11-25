// expect-error: cannot conform to 'PlainData'
import SwiftStateTree

// An @Internal field without a type annotation: its storage and value lines are written, and
// `Internal`'s constraint refuses the inferred type first.
@StateNodeBuilder
struct CacheState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    @Internal
    var cache = [String: Any]()

    init() {}
}
