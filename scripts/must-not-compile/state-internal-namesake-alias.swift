// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A typealias that names another wrapper `Internal`: the attribute's spelling matches, the
// storage is the other wrapper's, and that holds a class.
final class Handle: @unchecked Sendable {}

@propertyWrapper
struct Boxed<Value: Sendable>: Sendable {
    var wrappedValue: Value
    var handle = Handle()
}

typealias Internal = Boxed

@StateNodeBuilder
struct HandleState: StateNodeProtocol {
    @Internal
    var count: Int = 0

    init() {}
}
