// expect-error: to closure result type 'any PlainData'
import SwiftStateTurns

// The same as a dictionary's value: the macro checks the element.
protocol Loose: Sendable {}
@PlainData
struct Holder {
    var byName: [String: any Loose]
}
