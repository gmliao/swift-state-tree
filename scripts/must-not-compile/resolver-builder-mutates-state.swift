// expect-error: 'state' is a 'let' constant
// #769 §3.2: the resolvers closure reads State; it gets it as a constant.
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
        HandleAction(SnippetAction.self, resolvers: { state, action, _ in
            state.total += 1
            return Price(item: action.amount)
        }) { state, _, _, _ in
            SnippetResponse(total: state.total)
        }
    }
}
