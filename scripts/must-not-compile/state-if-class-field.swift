// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A class in a synced field inside `#if`: the PlainData check reads every clause.
final class Ledger: Codable, @unchecked Sendable {
    var total = 0
}

@StateNodeBuilder
struct LedgerState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    #if swift(>=5.0)
    @Sync(.broadcast)
    var ledger: Ledger = Ledger()
    #endif

    init() {}
}
