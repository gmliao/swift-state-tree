// expect: compiles
import SwiftStateTree

// The wrappers spelled with their module (SwiftStateTree, or SwiftStateTreeNIO, which re-exports
// it): read through as @Sync and @Internal. An observed @Internal field keeps its observer.
@StateNodeBuilder
struct QualifiedState: StateNodeProtocol {
    @SwiftStateTree.Sync(.broadcast)
    var count: Int = 0

    @SwiftStateTree.Internal
    var cache: [String: Int] = [:]

    @Internal
    var observed: Int = 0 {
        didSet {}
    }

    #if DEBUG
    @Internal
    var debugHits: Int = 0
    #endif

    init() {}
}
