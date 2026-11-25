// expect-error: Decimal isn't plain data
import Foundation
import SwiftStateTree

// A server-only Decimal: one Decimal message for every field, synced or not.
@StateNodeBuilder
struct PriceState: StateNodeProtocol {
    @Sync(.serverOnly)
    var price: Decimal = 0

    init() {}
}
