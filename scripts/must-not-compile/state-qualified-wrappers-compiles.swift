// expect: compiles
import SwiftStateTree

// The wrappers spelled with their module: read through as @Sync and @Internal, and synced.
@StateNodeBuilder
struct QualifiedState: StateNodeProtocol {
    @SwiftStateTree.Sync(.broadcast)
    var count: Int = 0

    @SwiftStateTree.Internal
    var cache: [String: Int] = [:]

    @Sync(.broadcast)
    var observed: Int = 0 {
        didSet {}
    }

    #if DEBUG
    @Internal
    var debugHits: Int = 0
    #endif

    init() {}
}
