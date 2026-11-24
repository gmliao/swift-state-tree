// expect-error: to closure result type 'any PlainData'
import SwiftStateTurns

// An optional existential whose protocol doesn't refine PlainData: the wrapped value is checked.
protocol Loose: Sendable {}
@PlainData
struct Holder {
    var next: (any Loose)?
}
