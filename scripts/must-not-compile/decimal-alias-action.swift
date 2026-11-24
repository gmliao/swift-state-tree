// expect-error: this field's type isn't PlainData
import SwiftStateTree
import Foundation

// A Decimal behind a typealias in an action: Decimal isn't PlainData (#597).
typealias Money = Decimal

@Payload
struct BuyAction: ActionPayload {
    typealias Response = SnippetResponse
    let amount: Money
}
