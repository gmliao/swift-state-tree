// expect-error: 'any Loose'
import SwiftStateTurns

// An array of an existential whose protocol doesn't refine PlainData: the element is checked.
protocol Loose: Sendable {}
@PlainData
struct Holder {
    var all: [any Loose]
}
