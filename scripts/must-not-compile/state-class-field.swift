// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A class in a synced field: the PlainData check @StateNodeBuilder writes refuses it, on the line
// that reads the field.
final class Ledger: Codable, @unchecked Sendable {
    var total = 0
}

@StateNodeBuilder
struct LedgerState: StateNodeProtocol {
    @Sync(.broadcast)
    var ledger: Ledger = Ledger()

    init() {}
}
