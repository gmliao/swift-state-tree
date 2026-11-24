// expect-error: 'HasPriceCache'
// #769 §3.4: a resolver's Dependencies is the land's Services, so a land whose services lack
// the capability the resolver needs doesn't compile at the declaration.
import SwiftStateTree

protocol HasPriceCache: Sendable {
    var prices: [Int: Int] { get }
}

struct ThinServices: Sendable {}

@PlainData
struct PriceOutput: ResolverOutput {
    let price: Int
}

@PlainData
struct Price<D: HasPriceCache>: Resolver {
    typealias Dependencies = D
    let item: Int
    func resolve(_ deps: D) async throws -> PriceOutput {
        PriceOutput(price: deps.prices[item] ?? 0)
    }
}

let land = Land("snippet", using: SnippetState.self, services: ThinServices.self) {
    Rules {
        HandleAction(SnippetAction.self, resolvers: { _, action, _ in Price(item: action.amount) }) { state, _, _, _ in
            SnippetResponse(total: state.total)
        }
    }
}
