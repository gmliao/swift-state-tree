// expect-error: 'Ref' does not conform to expected type 'PlainData'
import SwiftStateTurns

// A `Dictionary` alias that keeps its key and drops its value: the checks read the stored values.
protocol Payload: PlainData, Sendable {}

final class Ref: Sendable {}

typealias Dictionary<K: Hashable, V> = Swift.Dictionary<K, Ref>

@PlainData
struct Holds {
    var byName: Dictionary<String, any Payload>
}
