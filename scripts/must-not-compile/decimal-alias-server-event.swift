// expect-error: this field's type isn't PlainData
import SwiftStateTree
import Foundation

// A Decimal behind a typealias passes the macro, which sees only the spelling; the compiler
// refuses it, since Decimal isn't PlainData (#597).
typealias Money = Decimal

@Payload
struct PriceEvent: ServerEventPayload {
    let amount: Money
}
