// expect-error: to expected argument type '(Ref) -> Void'
import SwiftStateTurns

// An `Optional` alias that drops its argument: the closure binds the wrapped type.
protocol Payload: PlainData, Sendable {}

final class Ref: Sendable {}

typealias Optional<W> = Swift.Optional<Ref>

@PlainData
struct Holds {
    var maybe: Optional<any Payload>
}
