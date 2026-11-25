// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A wrapper of the user's own named `Internal`: the macro reads it through by name, but the
// PlainData check also reads its storage, `_cache`, which holds a class.
final class Cache: @unchecked Sendable {}

@propertyWrapper
struct Internal<Value: Sendable>: Sendable {
    var wrappedValue: Value
    var cache = Cache()
}

@StateNodeBuilder
struct CacheState: StateNodeProtocol {
    @Internal
    var hits: Int = 0

    init() {}
}
