// expect-error: does not conform to protocol 'PlainData'
import SwiftStateTree

// StateProtocol refines PlainData: a conformer without @PlainData or @SnapshotConvertible has no
// witness.
struct BareState: StateProtocol {
    var n: Int
}
