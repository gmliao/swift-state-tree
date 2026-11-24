// expect-error: 'Ref' conform to 'PlainData'
import SwiftStateTurns

// The conditional conformance holds only where the parent's parameter is PlainData.
struct Outer<T> {
    @PlainData
    struct Inner {
        var value: T
    }
}

final class Ref {}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Outer<Ref>.Inner.self)
}
