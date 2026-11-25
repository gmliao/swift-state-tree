import SwiftStateTurns

/// What an input gave its caller when it succeeded, inside the keeper: the action's response,
/// or nothing (every other input, and an action acknowledged before its tick).
///
/// The keeper holds a success as this, not as `AnyCodable`, from the handler to the transport:
/// `awaitActionResult` and `ActionSubmission.completed` return it, and the adapter encodes the
/// response from it (#700 K1a), so the response isn't boxed into `Any` on the way. Only the
/// public `handleActionEnvelope` converts it, with `boundaryValue`, to the value it returned
/// before. The frames don't change.
@PlainData
package enum InputOutcome: Sendable {
    case none
    case response(any ResponsePayload)

    /// The value `handleActionEnvelope` returns: an empty `AnyCodable` for `.none`, and the
    /// response itself, its concrete value, inside an `AnyCodable` for `.response`. Boxing the
    /// response allocates; the transport's reply doesn't take this path.
    package var boundaryValue: AnyCodable {
        switch self {
        case .none: return AnyCodable(())
        case .response(let response): return AnyCodable(response)
        }
    }
}
