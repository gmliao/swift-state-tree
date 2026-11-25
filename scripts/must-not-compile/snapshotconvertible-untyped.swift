// expect-error: needs a type annotation
import SwiftStateTree

// @SnapshotConvertible writes the PlainData check, which reads each stored property's declared
// type: a property without an annotation is refused.
@SnapshotConvertible
struct Loadout: Sendable {
    var byKey = [String: Int]()
}
