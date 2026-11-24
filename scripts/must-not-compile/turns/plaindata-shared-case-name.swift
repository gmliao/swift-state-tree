// expect-error: @PlainData can't check enum cases that share the base name 'item'
import SwiftStateTurns

// Valid Swift, but `if case let .item(v0) = value` is ambiguous, so the macro refuses it.
@PlainData
enum Entry {
    case item(count: Int)
    case item(label: String)
}
