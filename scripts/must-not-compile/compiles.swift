// expect: compiles
// The control: the two-stage forms and a non-throwing single closure typecheck, so a failure
// in the other snippets comes from what they test, not from the setup.
import SwiftStateTree

// A single-closure action that can't fail.
let compilesSingleAction = Land("snippet-single", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self) { (state: inout SnippetState, action: SnippetAction, _: LandContext) in
            state.total += action.amount
            return SnippetResponse(total: state.total)
        }
    }
}

// AnyActionHandler's public two-stage init, with the action's own Response.
let compilesErased = AnyActionHandler<SnippetState>(SnippetAction.self, validate: { (_: SnippetState, _: SnippetAction, _: ValidateContext) in
}, apply: { (state: inout SnippetState, _: SnippetAction, _: Void, _: LandContext) in
    SnippetResponse(total: state.total)
})

let compilesLand = Land("snippet", using: SnippetState.self) {
    ClientEvents { Register(SnippetEvent.self) }
    Rules {
        OnJoin { (state: inout SnippetState, _: LandContext) in state.total += 1 }
        HandleAction(SnippetAction.self, validate: { (state: SnippetState, action: SnippetAction, _: ValidateContext) -> Int in
            guard action.amount > 0 else { throw SnippetError() }
            return state.total + action.amount
        }, apply: { (state: inout SnippetState, _: SnippetAction, total: Int, _: LandContext) in
            state.total = total
            return SnippetResponse(total: total)
        })
        HandleEvent(SnippetEvent.self) { (state: inout SnippetState, event: SnippetEvent, _: LandContext) in
            state.total += event.amount
        }
        HandleServerInput(SnippetInput.self, validate: { (_: SnippetState, input: SnippetInput, _: ValidateContext) in
            guard input.amount > 0 else { throw SnippetError() }
        }, apply: { (state: inout SnippetState, input: SnippetInput, _: LandContext) in
            state.total += input.amount
        })
        OnLeave { (state: inout SnippetState, _: LandContext) in state.total -= 1 }
    }
}

// The lifecycle handlers (#593): destroy handlers and a single OnInitialize that can't fail,
// OnInitialize in two stages (with and without a plan), and InitializeHandler's public inits.
let compilesLifecycle = Land("snippet-lifecycle", using: SnippetState.self) {
    Lifetime {
        OnInitialize(validate: { (state: SnippetState, _: ValidateContext) -> Int in
            guard state.total == 0 else { throw SnippetError() }
            return 1
        }, apply: { (state: inout SnippetState, total: Int, _: LandContext) in
            state.total = total
        })
        DestroyWhenEmpty(after: .seconds(1)) { (state: inout SnippetState, _: LandContext) in state.total = 0 }
        OnFinalize { (state: inout SnippetState, _: LandContext) in state.total = 0 }
    }
}

let compilesSingleInitialize = Land("snippet-single-initialize", using: SnippetState.self) {
    Lifetime {
        OnInitialize { (state: inout SnippetState, _: LandContext) in state.total = 1 }
    }
}

// The two-stage DSL form without a plan, the one `throw-in-oninitialize-apply.swift` refuses.
let compilesVoidInitialize = Land("snippet-void-initialize", using: SnippetState.self) {
    Lifetime {
        OnInitialize(validate: { (state: SnippetState, _: ValidateContext) in
            guard state.total == 0 else { throw SnippetError() }
        }, apply: { (state: inout SnippetState, _: LandContext) in
            state.total = 1
        })
    }
}

let compilesInitializeHandlers: [InitializeHandler<SnippetState>] = [
    InitializeHandler { (state: inout SnippetState, _: LandContext) in state.total = 1 },
    InitializeHandler(validate: { (_: SnippetState, _: ValidateContext) in
        throw SnippetError()
    }, apply: { (state: inout SnippetState, _: LandContext) in
        state.total = 1
    }),
    InitializeHandler(validate: { (_: SnippetState, _: ValidateContext) -> Int in 1 },
                      apply: { (state: inout SnippetState, total: Int, _: LandContext) in state.total = total }),
]
