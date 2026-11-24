// expect-error: 'any Loose'
import SwiftStateTurns

// An existential field of a protocol that doesn't refine PlainData.
protocol Loose: Sendable {}
@PlainData
struct Holder {
    var value: any Loose
}
