// expect-error: cannot convert value of type 'TypedLand<SnippetState, ShopServices>'
// #769 R-Q1 (c): the untyped entry points take a definition, not a TypedLand.
import SwiftStateTree

struct ShopServices: Sendable {}

let land = Land("snippet", using: SnippetState.self, services: ShopServices.self) {
    Rules {
        HandleAction(SnippetAction.self) { state, _, _ in SnippetResponse(total: state.total) }
    }
}

let keeper = LandKeeper<SnippetState>(definition: land, initialState: SnippetState())
