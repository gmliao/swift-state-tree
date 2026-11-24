// expect-error: cannot convert value of type 'Array<any Payload>'
import SwiftStateTurns

// A typealias named `Array` that names the module's own type: the bare spelling is refused too.
protocol Payload: PlainData, Sendable {}
final class Ref {}
struct Mine<Element> {
    var ref: Ref
}
typealias Array<Element> = Mine<Element>
@PlainData
struct Holder {
    var items: Array<any Payload>
}
