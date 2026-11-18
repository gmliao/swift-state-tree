// Shared by every snippet in this directory (`scripts/check-must-not-compile.sh`).
import SwiftStateTree

@StateNodeBuilder
struct SnippetState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    init() {}
}

@Payload
struct SnippetResponse: ResponsePayload {
    let total: Int
}

@Payload
struct SnippetAction: ActionPayload {
    typealias Response = SnippetResponse
    let amount: Int
}

@Payload
struct SnippetEvent: ClientEventPayload {
    let amount: Int
}

struct SnippetError: Error {}
