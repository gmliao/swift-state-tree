// expect: compiles
import SwiftStateTurns

// `C.Element == T`: the field names `C`, and the requirement makes `T` named too, so
// `T: PlainData` proves `C.Element` plain data, as it did before #769 constrained only the
// parameters stored values name.
@PlainData
struct First<C: Collection & Sendable, T> where C.Element == T {
    let first: C.Element?
}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(First<[Int], Int>.self)
}
