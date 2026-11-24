// expect-error: 'Ref' conform to 'PlainData'
import SwiftStateTurns

// A stored parameter is constrained: `Box<Ref>` isn't plain data. With no constraint at all
// the declaration itself would fail, naming `T`, not `Ref`.
@PlainData
struct Box<T> { let t: T }

final class Ref {}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Box<Ref>.self)
}
