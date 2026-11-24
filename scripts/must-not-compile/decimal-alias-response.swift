// expect-error: this field's type isn't PlainData
import SwiftStateTree
import Foundation

// A Decimal behind a typealias in a response: Decimal isn't PlainData (#597).
typealias Money = Decimal

@Payload
struct BuyResponse: ResponsePayload {
    let totals: [String: Money]
}
