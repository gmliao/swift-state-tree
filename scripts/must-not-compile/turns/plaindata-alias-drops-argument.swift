// expect-error: 'Ref' does not conform to expected type 'PlainData'
import SwiftStateTurns

// The alias is the standard library's `Array`, so the helper accepts it, but it ignores its
// argument: `Array<any Payload>` is a `[Ref]`. The checks read the stored elements, which are
// `Ref`s, not the spelled `any Payload`.
protocol Payload: PlainData, Sendable {}

final class Ref: Sendable {}

typealias Array<E> = Swift.Array<Ref>

@PlainData
struct Holds {
    var items: Array<any Payload>
}
