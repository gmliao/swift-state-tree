// expect-error: 'HasPriceCache'
// #769 §4: @Land(…, services:) puts the body under the land's services, so a resolver needing a
// capability they lack doesn't compile.
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
    func resolve(_ deps: D) async throws -> PriceOutput { PriceOutput(price: deps.prices[item] ?? 0) }
}

@Land(SnippetState.self, id: "thin", services: ThinServices.self)
struct ThinLand {
    static var body: LandRules<SnippetState, ThinServices> {
        Rules {
            HandleAction(SnippetAction.self, resolvers: { _, action, _ in Price(item: action.amount) }) { state, _, _, _ in
                SnippetResponse(total: state.total)
            }
        }
    }
}
