// expect: compiles
import SwiftStateTree
import SwiftStateTurns

@PlainData
struct Scratch: Sendable {
    var hits: [String: Int]
}

// An @Internal value that is PlainData.
@StateNodeBuilder
struct ScratchState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    @Internal
    var scratch: Scratch = Scratch(hits: [:])

    init() {}
}
