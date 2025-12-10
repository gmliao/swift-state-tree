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

/// Message kind identifier for TransportMessage.
public enum MessageKind: String, Codable, Sendable {
    case action
    case actionResponse
    case event
    case join
    case joinResponse
    case error
}

/// Payload types for different message kinds.
public enum MessagePayload: Codable, Sendable {
    case action(TransportActionPayload)
    case actionResponse(TransportActionResponsePayload)
    case event(TransportEventPayload)
    case join(TransportJoinPayload)
    case joinResponse(TransportJoinResponsePayload)
    case error(ErrorPayload)
    
    private enum CodingKeys: String, CodingKey {
        case action
        case actionResponse
        case event
        case join
        case joinResponse
        case error
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let payload):
            try container.encode(payload, forKey: .action)
        case .actionResponse(let payload):
            try container.encode(payload, forKey: .actionResponse)
        case .event(let payload):
            try container.encode(payload, forKey: .event)
        case .join(let payload):
            try container.encode(payload, forKey: .join)
        case .joinResponse(let payload):
            try container.encode(payload, forKey: .joinResponse)
        case .error(let payload):
            try container.encode(payload, forKey: .error)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let action = try? container.decode(TransportActionPayload.self, forKey: .action) {
            self = .action(action)
        } else if let actionResponse = try? container.decode(TransportActionResponsePayload.self, forKey: .actionResponse) {
            self = .actionResponse(actionResponse)
        } else if let event = try? container.decode(TransportEventPayload.self, forKey: .event) {
            self = .event(event)
        } else if let join = try? container.decode(TransportJoinPayload.self, forKey: .join) {
            self = .join(join)
        } else if let joinResponse = try? container.decode(TransportJoinResponsePayload.self, forKey: .joinResponse) {
            self = .joinResponse(joinResponse)
        } else if let error = try? container.decode(ErrorPayload.self, forKey: .error) {
            self = .error(error)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unable to decode MessagePayload"
                )
            )
        }
    }
}

/// Action request payload for transport layer.
public struct TransportActionPayload: Codable, Sendable {
    public let requestID: String
    public let landID: String
    public let action: ActionEnvelope
    
    public init(requestID: String, landID: String, action: ActionEnvelope) {
        self.requestID = requestID
        self.landID = landID
        self.action = action
    }
}

/// Action response payload for transport layer.
public struct TransportActionResponsePayload: Codable, Sendable {
    public let requestID: String
    public let response: AnyCodable
    
    public init(requestID: String, response: AnyCodable) {
        self.requestID = requestID
        self.response = response
    }
}

/// Event payload for transport layer.
public struct TransportEventPayload: Codable, Sendable {
    public let landID: String
    public let event: TransportEvent
    
    public init(landID: String, event: TransportEvent) {
        self.landID = landID
        self.event = event
    }
}

/// Join request payload for transport layer.
public struct TransportJoinPayload: Codable, Sendable {
    public let requestID: String
    public let landID: String
    public let playerID: String?
    public let deviceID: String?
    public let metadata: [String: AnyCodable]?
    
    public init(requestID: String, landID: String, playerID: String?, deviceID: String?, metadata: [String: AnyCodable]?) {
        self.requestID = requestID
        self.landID = landID
        self.playerID = playerID
        self.deviceID = deviceID
        self.metadata = metadata
    }
}

/// Join response payload for transport layer.
public struct TransportJoinResponsePayload: Codable, Sendable {
    public let requestID: String
    public let success: Bool
    public let playerID: String?
    public let reason: String?
    
    public init(requestID: String, success: Bool, playerID: String?, reason: String?) {
        self.requestID = requestID
        self.success = success
        self.playerID = playerID
        self.reason = reason
    }
}

/// Transport Message wrapping action calls, responses, and events.
///
/// Uses unified `kind` field for type identification and `payload` for the actual data.
/// This provides better maintainability and extensibility compared to optional fields.
public struct TransportMessage: Codable, Sendable {
    public let kind: MessageKind
    public let payload: MessagePayload
    
    public init(kind: MessageKind, payload: MessagePayload) {
        self.kind = kind
        self.payload = payload
    }
    
    // Convenience initializers
    public static func action(requestID: String, landID: String, action: ActionEnvelope) -> TransportMessage {
        return TransportMessage(
            kind: .action,
            payload: .action(TransportActionPayload(requestID: requestID, landID: landID, action: action))
        )
    }
    
    public static func actionResponse(requestID: String, response: AnyCodable) -> TransportMessage {
        return TransportMessage(
            kind: .actionResponse,
            payload: .actionResponse(TransportActionResponsePayload(requestID: requestID, response: response))
        )
    }
    
    public static func event(landID: String, event: TransportEvent) -> TransportMessage {
        return TransportMessage(
            kind: .event,
            payload: .event(TransportEventPayload(landID: landID, event: event))
        )
    }
    
    public static func join(requestID: String, landID: String, playerID: String?, deviceID: String?, metadata: [String: AnyCodable]?) -> TransportMessage {
        return TransportMessage(
            kind: .join,
            payload: .join(TransportJoinPayload(requestID: requestID, landID: landID, playerID: playerID, deviceID: deviceID, metadata: metadata))
        )
    }
    
    public static func joinResponse(requestID: String, success: Bool, playerID: String?, reason: String?) -> TransportMessage {
        return TransportMessage(
            kind: .joinResponse,
            payload: .joinResponse(TransportJoinResponsePayload(requestID: requestID, success: success, playerID: playerID, reason: reason))
        )
    }
    
    public static func error(_ errorPayload: ErrorPayload) -> TransportMessage {
        return TransportMessage(
            kind: .error,
            payload: .error(errorPayload)
        )
    }
}

/// Transport event container using fixed root types.
public enum TransportEvent: Codable, Sendable {
    case fromClient(event: AnyClientEvent)
    case fromServer(event: AnyServerEvent)
}
