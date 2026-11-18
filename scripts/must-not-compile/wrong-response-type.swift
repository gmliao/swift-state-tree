// expect-error: cannot convert value of type 'String' to closure result type
// A handler returns its action's declared Response (#586, #561).
import SwiftStateTree

let wrongResponse = Land("snippet", using: SnippetState.self) {
    Rules {
        HandleAction(SnippetAction.self) { (_: inout SnippetState, _: SnippetAction, _: LandContext) in
            return "done"
        }
    }
}
