// expect-error: must be marked with @Sync or @Internal
import SwiftStateTree

// Observers keep a property stored, so an observed property needs a marker like any other.
@StateNodeBuilder
struct ObservedState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    var secret: Int = 0 {
        didSet {}
    }

    init() {}
}
