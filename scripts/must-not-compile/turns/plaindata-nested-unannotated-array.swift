// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

struct Spot: Sendable {
    var x: Int
}

@PlainData
struct Board {
    var spots: [Spot]
}
