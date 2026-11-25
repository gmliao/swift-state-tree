// expect-error: this field's type isn't PlainData
// #769 §3.1: a resolver is PlainData, so it can't hold a reference.
import SwiftStateTree

final class Connection: @unchecked Sendable {}

@PlainData
struct PriceOutput: ResolverOutput {
    let price: Int
}

@PlainData
struct Fetch: Resolver {
    typealias Dependencies = NoServices
    let connection: Connection
    func resolve(_ deps: NoServices) async throws -> PriceOutput { PriceOutput(price: 0) }
}
