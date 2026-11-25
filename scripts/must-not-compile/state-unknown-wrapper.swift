// expect-error: the PlainData check reads only @Internal and @Sync fields
import SwiftStateTree

// A property wrapper other than @Sync and @Internal on a state field: its storage can't be
// checked, so it is refused.
@propertyWrapper
struct Clamped: Sendable {
    var wrappedValue: Int
}

@StateNodeBuilder
struct ClampState: StateNodeProtocol {
    @Sync(.broadcast) @Clamped
    var level: Int = 0

    init() {}
}
