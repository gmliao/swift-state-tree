// expect-error: has no member 'random'
// #769 §3.6: the resolvers closure draws nothing from the land's RNG; its context has none.
import SwiftStateTree

@PlainData
struct PriceOutput: ResolverOutput {
    let price: Int
}

@PlainData
struct Price: Resolver {
    typealias Dependencies = NoServices
    let item: Int
    func resolve(_ deps: NoServices) async throws -> PriceOutput { PriceOutput(price: item) }
}

let land = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self, resolvers: { _, _, ctx in
            Price(item: ctx.random.nextInt(in: 0...9))
        }) { state, _, _, _ in
            SnippetResponse(total: state.total)
        }
    }
}
