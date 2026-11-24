// expect-error: 'any Loose'
import SwiftStateTurns

// The same as a dictionary's value: the macro checks the element.
protocol Loose: Sendable {}
@PlainData
struct Holder {
    var byName: [String: any Loose]
}
