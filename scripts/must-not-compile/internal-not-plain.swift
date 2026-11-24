// expect-error: conform to 'PlainData'
import SwiftStateTree

// An @Internal value is PlainData (#767): a dictionary of `Any` isn't.
@StateNodeBuilder
struct CacheState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    @Internal
    var cache: [String: Any] = [:]

    init() {}
}
