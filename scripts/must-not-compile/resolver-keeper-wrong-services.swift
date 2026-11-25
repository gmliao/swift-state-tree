// expect-error: cannot convert value of type 'OtherServices'
// #769 R-Q1 (c): the typed keeper takes only the land's services type, as the typed
// registration's factory does.
import SwiftStateTree

struct ShopServices: Sendable {}
struct OtherServices: Sendable {}

let land = Land("snippet", using: SnippetState.self, services: ShopServices.self) {
    Rules {
        HandleAction(SnippetAction.self) { state, _, _ in SnippetResponse(total: state.total) }
    }
}

let keeper = LandKeeper(land: land, resolverServices: OtherServices(), initialState: SnippetState())
