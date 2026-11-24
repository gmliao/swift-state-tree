// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A class field: a payload's fields are checked as @PlainData's are, so a reference is refused.
final class Ledger: Codable, @unchecked Sendable {
    var total = 0
}

@Payload
struct LedgerEvent: ServerEventPayload {
    let ledger: Ledger
}
