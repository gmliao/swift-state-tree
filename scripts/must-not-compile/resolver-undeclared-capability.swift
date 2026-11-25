// expect-error: has no member 'prices'
// #769 §3.4: resolve sees only what its Dependencies declares.
import SwiftStateTree

protocol HasPriceCache: Sendable {
    var prices: [Int: Int] { get }
}

protocol HasClock: Sendable {
    var now: Int { get }
}

@PlainData
struct PriceOutput: ResolverOutput {
    let price: Int
}

@PlainData
struct Price<D: HasClock>: Resolver {
    typealias Dependencies = D
    let item: Int
    func resolve(_ deps: D) async throws -> PriceOutput {
        PriceOutput(price: deps.prices[item] ?? 0)
    }
}
