// expect-error: @StateNodeBuilder writes the PlainData check; remove @PlainData
import SwiftStateTree

// @PlainData beside @StateNodeBuilder would write a second witness.
@PlainData
@StateNodeBuilder
struct CountState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    init() {}
}
