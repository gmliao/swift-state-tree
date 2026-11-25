// expect-error: cannot conform to 'PlainData'
import SwiftStateTree

// An existential behind a typealias, which the #535 spelling check can't see: `Sync`'s
// constraint refuses it, so the gap #535 documented is closed at compile time.
protocol Shape: Sendable {}
extension Int: Shape {}
typealias AnyShape = any Shape

@StateNodeBuilder
struct ShapeState: StateNodeProtocol {
    @Sync(.broadcast)
    var shape: AnyShape = 0

    init() {}
}
