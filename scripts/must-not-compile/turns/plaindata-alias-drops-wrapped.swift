// expect-error: 'Ref' conform to 'PlainData'
import SwiftStateTurns

// An `Optional` alias that drops its argument: the checks read the wrapped value.
protocol Payload: PlainData, Sendable {}

final class Ref: Sendable {}

typealias Optional<W> = Swift.Optional<Ref>

@PlainData
struct Holds {
    var maybe: Optional<any Payload>
}
