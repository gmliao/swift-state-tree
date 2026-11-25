// expect-error: must be marked with @Sync or @Internal
import SwiftStateTree

enum Other {
    @propertyWrapper
    struct Sync<Value> {
        var wrappedValue: Value
        init(wrappedValue: Value, _ policy: Int) { self.wrappedValue = wrappedValue }
    }
}

// Only a module that declares or re-exports the wrapper qualifies it: `@Other.Sync` isn't the
// library's marker, so the field counts as unmarked.
@StateNodeBuilder
struct OtherQualifiedState: StateNodeProtocol {
    @Other.Sync(0)
    var hp: Int = 0

    init() {}
}
