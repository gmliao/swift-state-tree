import SwiftStateTurns

/// What an input gave its caller when it succeeded, inside the keeper: the action's response,
/// or nothing (every other input, and an action acknowledged before its tick).
///
/// The keeper holds a success as this, not as `AnyCodable`, from the handler to its exits.
/// The exits (`awaitActionResult` and `ActionSubmission.completed`) convert it with
/// `boundaryValue`, to the value they returned before; `handleActionEnvelope` forwards what
/// they return. So the transport and its frames don't change.
@PlainData
enum InputOutcome: Sendable {
    case none
    case response(any ResponsePayload)

    /// The value the keeper's exits return: an empty `AnyCodable` for `.none`, and the response
    /// itself, its concrete value, inside an `AnyCodable` for `.response`.
    var boundaryValue: AnyCodable {
        switch self {
        case .none: return AnyCodable(())
        case .response(let response): return AnyCodable(response)
        }
    }
}
