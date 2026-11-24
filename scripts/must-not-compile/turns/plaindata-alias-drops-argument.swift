// expect-error: to expected argument type '(Ref) -> Void'
import SwiftStateTurns

// The alias is the standard library's `Array`, so the pinned helper's first parameter accepts
// it, but it ignores its argument: `Array<any Payload>` is a `[Ref]`, and the existential check
// sees only the spelled `any Payload`. The closure binds the element to the spelled one.
protocol Payload: PlainData, Sendable {}

final class Ref: Sendable {}

typealias Array<E> = Swift.Array<Ref>

@PlainData
struct Holds {
    var items: Array<any Payload>
}
