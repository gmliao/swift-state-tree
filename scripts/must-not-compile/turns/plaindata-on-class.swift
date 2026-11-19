// expect-error: @PlainData applies to a struct or an enum
import SwiftStateTurns

// @PlainData on a class.
@PlainData
final class Box {
    var n: Int = 0
}
