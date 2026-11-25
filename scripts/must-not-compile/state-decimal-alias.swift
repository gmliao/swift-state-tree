// expect-error: conform to 'PlainData'
import Foundation
import SwiftStateTree

// A Decimal behind a typealias, which no spelling check can see: `Sync`'s constraint refuses it,
// since Decimal isn't PlainData.
typealias Money = Decimal

@StateNodeBuilder
struct PriceState: StateNodeProtocol {
    @Sync(.broadcast)
    var price: Money = 0

    init() {}
}
