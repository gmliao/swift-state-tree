// expect-error: 'Ref' conform to 'PlainData'
import SwiftStateTurns

// A field of a type the body declares constrains every parameter, `B` included, though no
// field names `B`: the macro can't see which parameters such a type captures.
@PlainData
struct Outer<A, B> {
    @PlainData
    struct Inner { let x: Int }
    let inner: Inner
    let a: A
}

final class Ref {}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Outer<Int, Ref>.self)
}
