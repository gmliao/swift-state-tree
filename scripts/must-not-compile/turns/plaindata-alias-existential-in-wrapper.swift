// expect-error: must be spelled `any P` where the field is declared, not through an alias
import SwiftStateTurns

// An alias hides the `any` from the macro, so `[PayloadValue]` gets a `field` check, which an
// array of existentials can't pass; the error says how to spell it.
protocol Payload: PlainData {}
typealias PayloadValue = any Payload

@PlainData
struct Queue {
    var items: [PayloadValue]
}
