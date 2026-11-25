// expect-error: this field's type isn't PlainData
import SwiftStateTree

// The same namesake on a field without a type annotation: the namesake has no PlainData
// constraint, so the storage check (and the value line, which reads the same class) refuses it.
final class Ref: @unchecked Sendable {}

@propertyWrapper
struct Internal<Value: Sendable>: Sendable {
    var wrappedValue: Value
}

@StateNodeBuilder
struct RefState: StateNodeProtocol {
    @Internal
    var ref = Ref()

    init() {}
}
