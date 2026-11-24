// expect-error: 'Ref' conform to 'PlainData'
import SwiftStateTurns

// A field of a typealias the body declares constrains every parameter.
@PlainData
struct Aliased<A, B> {
    typealias Count = Int
    let count: Count
}

final class Ref {}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Aliased<Ref, Ref>.self)
}
