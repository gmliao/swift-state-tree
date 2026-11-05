import Foundation

/// What a number or boolean that `JSONSerialization` parsed was in the JSON text (#171).
///
/// `JSONSerialization` returns every JSON number and boolean as an `NSNumber`, and an `NSNumber`
/// holding 0 or 1 casts to `Bool`, so `as Bool` before `as Int` reads a JSON `0` or `1` as a
/// boolean. Classify such values with `JSONSerializationNumber(_:)` instead of casting.
package enum JSONSerializationNumber: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    /// An unsigned integer above `Int.max`.
    case unsigned(UInt64)
    case double(Double)

    /// Classifies `value` if it is an `NSNumber` instance, as `JSONSerialization` returns; `nil`
    /// for anything else, including native Swift `Bool`, `Int` and `Double` values.
    package init?(_ value: Any) {
        guard type(of: value) is NSNumber.Type, let number = value as? NSNumber else { return nil }
        switch String(cString: number.objCType) {
        case "c", "B":
            // A boolean NSNumber (CFBoolean on Darwin) reports a char type
            self = .bool(number.boolValue)
        case "f", "d":
            self = .double(number.doubleValue)
        case "Q":
            let unsigned = number.uint64Value
            if let int = Int(exactly: unsigned) {
                self = .int(int)
            } else {
                self = .unsigned(unsigned)
            }
        default:
            self = .int(number.intValue)
        }
    }
}
