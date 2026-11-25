// expect-error: cannot conform to 'PlainData'
import SwiftStateTree

// An @Internal existential, even of a protocol that refines PlainData: `Internal`'s constraint
// refuses it, since an existential doesn't conform.
protocol Token: PlainData, Sendable {}

@StateNodeBuilder
struct TokenState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    @Internal
    var token: (any Token)? = nil

    init() {}
}
