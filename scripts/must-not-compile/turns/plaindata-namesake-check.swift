// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

// A namesake `PlainDataCheck` with permissive overloads in the module doesn't turn the checks
// off: the expansion names `SwiftStateTurns.PlainDataCheck`.
enum PlainDataCheck {
    static func field<T>(_: T) {}
    static func existential(_: Any) {}
}
final class Ref {}
@PlainData
struct Holder {
    var ref: Ref
}
