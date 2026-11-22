// expect-error: conform to 'PlainData'
import SwiftStateTree
import Foundation

// Decimal isn't PlainData (a smallest-unit integer or a String is), so @Internal refuses it.
@StateNodeBuilder
struct MoneyState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    @Internal
    var scratch: Decimal = 0

    init() {}
}
