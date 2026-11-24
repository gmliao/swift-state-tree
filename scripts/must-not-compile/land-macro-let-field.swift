// expect-error: cannot assign to property: 'amount' is a 'let' constant
// #771 D-Q5: in a `body` the macro put under the builder, the closures get the real types, as
// with a hand-written attribute: assigning to the action's `let` field is the usual error.
import SwiftStateTree

@Land(SnippetState.self)
struct SnippetLetFieldLand {
    static var body: [LandNode] {
        Rules {
            HandleAction(SnippetAction.self) { state, action, _ in
                action.amount = 1
                return SnippetResponse(total: state.total)
            }
        }
    }
}
