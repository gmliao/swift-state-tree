// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

// A nested struct of the user's own without `@PlainData`: the error names the fix, on the
// expansion's line for the field `spot`.
struct Spot: Sendable {
    var x: Int
}

@PlainData
struct Board {
    var spot: Spot
}
