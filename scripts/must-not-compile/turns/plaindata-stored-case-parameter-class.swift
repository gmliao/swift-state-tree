// expect-error: 'Ref' conform to 'PlainData'
import SwiftStateTurns

// A parameter an enum case stores is constrained.
@PlainData
enum Choice<T, U> {
    case some(T)
    case none
}

final class Ref {}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Choice<Ref, Int>.self)
}
