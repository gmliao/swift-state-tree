// expect-error: 'any Loose'
import SwiftStateTurns

// An optional existential whose protocol doesn't refine PlainData: the wrapped value is checked.
protocol Loose: Sendable {}
@PlainData
struct Holder {
    var next: (any Loose)?
}
