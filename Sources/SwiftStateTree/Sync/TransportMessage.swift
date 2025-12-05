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

/// Transport Message wrapping action calls, responses, and events.
///
/// Uses fixed root types `AnyClientEvent` and `AnyServerEvent` instead of generics.
public enum TransportMessage: Codable, Sendable {
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
        event: TransportEvent
    )
}

/// Transport event container using fixed root types.
public enum TransportEvent: Codable, Sendable {
    case fromClient(AnyClientEvent)
    case fromServer(AnyServerEvent)
}
