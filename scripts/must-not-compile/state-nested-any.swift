// expect-error: Any
import SwiftStateTree

// A nested @PlainData struct holding `Any`: @PlainData refuses it on the nested type, so the
// gap #535 documented (a plain struct's own `Any` property) is closed at compile time.
@PlainData
struct Holder: @unchecked Sendable {
    var value: Any = 0
}

@StateNodeBuilder
struct HolderState: StateNodeProtocol {
    @Sync(.broadcast)
    var holder: Holder = Holder()

    init() {}
}
