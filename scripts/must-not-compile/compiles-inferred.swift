// expect: compiles
// #771: handler closures written without annotations. The land's builder gives every entry its
// State, `Rules` inside `Rules` included, and `Lifetime`'s directives too; a two-stage form
// infers its plan from `validate`.
import SwiftStateTree

let compilesInferred = Land("snippet-inferred", using: SnippetState.self) {
    ClientEvents { Register(SnippetEvent.self) }
    Rules {
        CanJoin { state, session, _ in
            state.total < 4 ? .allow(playerID: PlayerID(session.playerID)) : .deny(reason: "full")
        }
        OnJoin { state, _ in state.total += 1 }
        OnLeave { state, _ in state.total -= 1 }
        HandleAction(SnippetAction.self) { state, action, _ in
            state.total += action.amount
            return SnippetResponse(total: state.total)
        }
        HandleEvent(SnippetEvent.self) { state, event, _ in state.total += event.amount }
        Rules {
            HandleServerInput(SnippetInput.self, validate: { state, input, _ in
                guard input.amount > 0 else { throw SnippetError() }
                let next = state.total + input.amount
                return (next, input.amount)
            }, apply: { state, _, plan, _ in
                state.total = plan.0
            })
        }
    }
    Lifetime {
        Tick(every: .milliseconds(100)) { state, _ in state.total += 0 }
        OnInitialize(validate: { state, _ in
            guard state.total == 0 else { throw SnippetError() }
            return 1
        }, apply: { state, total, _ in
            state.total = total
        })
        DestroyWhenEmpty(after: .seconds(1)) { state, _ in state.total = 0 }
        OnFinalize { state, _ in state.total = 0 }
    }
}
