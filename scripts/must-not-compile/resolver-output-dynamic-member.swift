// expect-error: has no member 'price'
// #769 §3.3: a handler gets its resolver outputs as parameters; the context's dynamic member
// lookup for them is gone.
import SwiftStateTree

@PlainData
struct PriceOutput: ResolverOutput {
    let price: Int
}

@PlainData
struct PriceResolver: Resolver {
    typealias Dependencies = NoServices
    let item: Int
    func resolve(_ deps: NoServices) async throws -> PriceOutput { PriceOutput(price: item) }
}

let land = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self, resolvers: { _, action, _ in PriceResolver(item: action.amount) }) { state, _, _, ctx in
            let output: PriceOutput? = ctx.price
            return SnippetResponse(total: output?.price ?? state.total)
        }
    }
}
