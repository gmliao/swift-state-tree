// expect-error: cannot conform to 'PlainData'
import SwiftStateTree

// An @Internal field without a type annotation: nothing is emitted for it, and `Internal`'s
// constraint checks the inferred type.
@StateNodeBuilder
struct CacheState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    @Internal
    var cache = [String: Any]()

    init() {}
}
