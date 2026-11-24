// expect: compiles
import SwiftStateTree

// No `import SwiftStateTurns`: SwiftStateTree re-exports it, so `@PlainData` and the names its
// expansion writes resolve here (#79).
@PlainData
struct Tally: Sendable {
    var hits: [String: Int]
}

@StateNodeBuilder
struct TallyState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    @Internal
    var tally: Tally = Tally(hits: [:])

    init() {}
}
