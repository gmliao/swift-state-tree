// expect-error: conform to 'PlainData'
import SwiftStateTurns

// A namesake `PlainDataCheck` with permissive overloads in the module doesn't turn the checks
// off: the expansion names `SwiftStateTurns.PlainDataCheck`.
enum PlainDataCheck {
    static func field<T>(_: T.Type) {}
    static func existential<E>(_ upcast: (E) -> Any) {}
}
final class Ref {}
@PlainData
struct Holder {
    var ref: Ref
}
