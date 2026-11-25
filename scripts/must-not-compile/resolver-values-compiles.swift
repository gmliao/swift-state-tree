// expect: compiles
// #769 R1: a resolver generic over a capability it doesn't store is a value in a land whose
// services have the capability; @Land takes the services type; a typed keeper gets the value.
import SwiftStateTree

protocol HasPriceCache: Sendable {
    var prices: [Int: Int] { get }
}

struct ShopServices: HasPriceCache {
    let prices: [Int: Int]
}

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

@Land(SnippetState.self, id: "shop", services: ShopServices.self)
struct ShopLand {
    static var body: LandRules<SnippetState, ShopServices> {
        Rules {
            HandleAction(SnippetAction.self, resolvers: { state, action, _ in
                state.total > 0 ? Price(item: action.amount) : nil
            }) { state, action, price, _ in
                state.total += price?.price ?? action.amount
                return SnippetResponse(total: state.total)
            }
        }
    }
}

func makeKeeper() -> LandKeeper<SnippetState> {
    LandKeeper(land: ShopLand.definition, resolverServices: ShopServices(prices: [:]), initialState: SnippetState())
}
