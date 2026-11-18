// expect-error: cannot convert value of type 'String' to closure result type
// AnyActionHandler's public init answers with the action's declared Response (#586, #561).
import SwiftStateTree

let erasedWrongResponse = AnyActionHandler<SnippetState>(SnippetAction.self, validate: { (_: SnippetState, _: SnippetAction, _: ValidateContext) in
}, apply: { (_: inout SnippetState, _: SnippetAction, _: Void, _: LandContext) in
    return "done"
})
