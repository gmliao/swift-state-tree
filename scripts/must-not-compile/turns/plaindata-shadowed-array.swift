// expect-error: cannot convert value of type 'Swift.Array<
import SwiftStateTurns

// The module's own `Array` holds a class and a closure. Spelled `Array<any Payload>`, the macro
// can't tell it from the standard library's by its name: the identity check refuses it.
protocol Payload: PlainData, Sendable {}
final class Ref {}
struct Array<Element> {
    var ref: Ref
    var callback: () -> Void
}
@PlainData
struct Holder {
    var items: Array<any Payload>
}
