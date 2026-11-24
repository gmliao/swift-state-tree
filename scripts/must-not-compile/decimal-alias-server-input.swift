// expect-error: this field's type isn't PlainData
import SwiftStateTree
import Foundation

// A Decimal behind a typealias in a server input: Decimal isn't PlainData (#597).
typealias Money = Decimal

@Payload
struct Refund: ServerInputPayload {
    let amount: Money
}
