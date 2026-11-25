// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A class in an @Internal field inside `#if` (a @Sync field there is refused on its own): the
// PlainData check reads every clause.
final class Ledger: Codable, @unchecked Sendable {
    var total = 0
}

@StateNodeBuilder
struct LedgerState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    #if swift(>=5.0)
    @Internal
    var ledger: Ledger = Ledger()
    #endif

    init() {}
}
