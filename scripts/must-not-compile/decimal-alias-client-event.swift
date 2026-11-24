// expect-error: this field's type isn't PlainData
import SwiftStateTree
import Foundation

// A Decimal behind a typealias, in a container: Decimal isn't PlainData (#597).
typealias Money = Decimal

@Payload
struct BidEvent: ClientEventPayload {
    let offers: [Money]
}
