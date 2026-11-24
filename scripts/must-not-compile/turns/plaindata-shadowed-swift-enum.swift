// expect-error: cannot convert value of type 'Swift.Array<
import SwiftStateTurns

// A module-level `enum Swift` makes `Swift.Array<any Payload>` the module's own type, which holds
// a class and a closure. The pinned helper names the standard library's `Array` inside
// SwiftStateTurns, so it refuses this one.
protocol Payload: PlainData, Sendable {}
final class Ref {}
enum Swift {
    struct Array<Element> {
        var ref: Ref
        var callback: () -> Void
    }
}
@PlainData
struct Holder {
    var items: Swift.Array<any Payload>
}
