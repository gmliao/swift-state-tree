// expect-error: to expected argument type '(String, Ref) -> Void'
import SwiftStateTurns

// A `Dictionary` alias that keeps its key and drops its value: the closure binds both.
protocol Payload: PlainData, Sendable {}

final class Ref: Sendable {}

typealias Dictionary<K: Hashable, V> = Swift.Dictionary<K, Ref>

@PlainData
struct Holds {
    var byName: Dictionary<String, any Payload>
}
