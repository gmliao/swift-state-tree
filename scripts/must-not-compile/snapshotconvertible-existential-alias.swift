// expect-error: this field's type isn't PlainData
import SwiftStateTree

// An existential behind a typealias in a @SnapshotConvertible type: the PlainData check the macro
// writes refuses it, so #535's documented gap is closed for state value types too.
typealias AnyConvertible = any SnapshotValueConvertible

@SnapshotConvertible
struct Forms {
    let existential: AnyConvertible
}
