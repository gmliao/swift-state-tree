import Foundation

/// Generic Transport Message
///
/// Wraps action calls, responses, and events.
public enum TransportMessage<Action, ClientE, ServerE>: Codable
where
    Action: ActionPayload,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
{
    case action(
        requestID: String,
        landID: String,
        action: Action
    )

    case actionResponse(
        requestID: String,
        response: Action.Response
    )

    case event(
        landID: String,
        event: Event<ClientE, ServerE>
    )
}
