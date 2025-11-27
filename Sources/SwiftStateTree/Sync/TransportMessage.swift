import Foundation

/// Encoded action payload and metadata used by the transport layer.
public struct ActionEnvelope: Codable, Sendable {
    public let typeIdentifier: String
    public let payload: Data

    public init(typeIdentifier: String, payload: Data) {
        self.typeIdentifier = typeIdentifier
        self.payload = payload
    }
}

/// Generic Transport Message wrapping action calls, responses, and events.
public enum TransportMessage<ClientE, ServerE>: Codable
where
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload {
    case action(
        requestID: String,
        landID: String,
        action: ActionEnvelope
    )

    case actionResponse(
        requestID: String,
        response: AnyCodable
    )

    case event(
        landID: String,
        event: Event<ClientE, ServerE>
    )
}
