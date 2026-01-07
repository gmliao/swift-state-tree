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
    case event(TransportEvent)
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
        // For simplified event structure
        case fromClient
        case fromServer
        // For simplified action structure
        case requestID
        case typeIdentifier
        case payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let payload):
            // Simplified: encode action fields directly (flattened, not nested in "action")
            // Encoded format: { requestID: string, typeIdentifier: string, payload: Data }
            try container.encode(payload.requestID, forKey: .requestID)
            try container.encode(payload.action.typeIdentifier, forKey: .typeIdentifier)
            try container.encode(payload.action.payload, forKey: .payload)
        case .actionResponse(let payload):
            try container.encode(payload, forKey: .actionResponse)
        case .event(let event):
            // Simplified: encode TransportEvent directly (flattened format)
            // Encoded format: { fromClient: {...} } or { fromServer: {...} }
            switch event {
            case .fromClient(let clientEvent):
                try container.encode(clientEvent, forKey: .fromClient)
            case .fromServer(let serverEvent):
                try container.encode(serverEvent, forKey: .fromServer)
            }
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

        // Simplified: decode action fields directly (flattened format)
        // Decoded format: { requestID: string, typeIdentifier: string, payload: Data }
        if let requestID = try? container.decode(String.self, forKey: .requestID),
           let typeIdentifier = try? container.decode(String.self, forKey: .typeIdentifier),
           let payload = try? container.decode(Data.self, forKey: .payload) {
            let actionEnvelope = ActionEnvelope(typeIdentifier: typeIdentifier, payload: payload)
            let actionPayload = TransportActionPayload(requestID: requestID, action: actionEnvelope)
            self = .action(actionPayload)
        } else if let actionResponse = try? container.decode(TransportActionResponsePayload.self, forKey: .actionResponse) {
            self = .actionResponse(actionResponse)
        } else if let fromClient = try? container.decode(AnyClientEvent.self, forKey: .fromClient) {
            self = .event(.fromClient(event: fromClient))
        } else if let fromServer = try? container.decode(AnyServerEvent.self, forKey: .fromServer) {
            self = .event(.fromServer(event: fromServer))
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
///
/// Note: The encoded format is simplified - fields are flattened in MessagePayload:
/// - requestID, typeIdentifier, payload are encoded directly (not nested in "action")
/// - This struct still uses ActionEnvelope internally for type safety
public struct TransportActionPayload: Codable, Sendable {
    public let requestID: String
    // landID removed - server identifies land from session mapping
    public let action: ActionEnvelope
    
    public init(requestID: String, action: ActionEnvelope) {
        self.requestID = requestID
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

// TransportEventPayload removed - TransportEvent is now used directly in MessagePayload

/// Join request payload for transport layer.
///
/// Uses `landType` (required) and `landInstanceId` (optional) instead of `landID`.
/// - If `landInstanceId` is provided: Join an existing room
/// - If `landInstanceId` is nil: Create a new room and return the generated instanceId
public struct TransportJoinPayload: Codable, Sendable {
    public let requestID: String
    /// The type of Land to join (required)
    public let landType: String
    /// The specific instance to join (optional, if nil a new room will be created)
    public let landInstanceId: String?
    public let playerID: String?
    public let deviceID: String?
    public let metadata: [String: AnyCodable]?

    public init(
        requestID: String,
        landType: String,
        landInstanceId: String? = nil,
        playerID: String? = nil,
        deviceID: String? = nil,
        metadata: [String: AnyCodable]? = nil
    ) {
        self.requestID = requestID
        self.landType = landType
        self.landInstanceId = landInstanceId
        self.playerID = playerID
        self.deviceID = deviceID
        self.metadata = metadata
    }
}

/// Join response payload for transport layer.
public struct TransportJoinResponsePayload: Codable, Sendable {
    public let requestID: String
    public let success: Bool
    /// The type of Land joined
    public let landType: String?
    /// The instance ID of the Land joined
    public let landInstanceId: String?
    /// The complete landID (landType:instanceId)
    public let landID: String?
    public let playerID: String?
    public let reason: String?

    public init(
        requestID: String,
        success: Bool,
        landType: String? = nil,
        landInstanceId: String? = nil,
        landID: String? = nil,
        playerID: String? = nil,
        reason: String? = nil
    ) {
        self.requestID = requestID
        self.success = success
        self.landType = landType
        self.landInstanceId = landInstanceId
        self.landID = landID
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
    public static func action(requestID: String, action: ActionEnvelope) -> TransportMessage {
        return TransportMessage(
            kind: .action,
            payload: .action(TransportActionPayload(requestID: requestID, action: action))
        )
    }

    public static func actionResponse(requestID: String, response: AnyCodable) -> TransportMessage {
        return TransportMessage(
            kind: .actionResponse,
            payload: .actionResponse(TransportActionResponsePayload(requestID: requestID, response: response))
        )
    }

    public static func event(event: TransportEvent) -> TransportMessage {
        return TransportMessage(
            kind: .event,
            payload: .event(event)
        )
    }

    public static func join(
        requestID: String,
        landType: String,
        landInstanceId: String? = nil,
        playerID: String? = nil,
        deviceID: String? = nil,
        metadata: [String: AnyCodable]? = nil
    ) -> TransportMessage {
        return TransportMessage(
            kind: .join,
            payload: .join(TransportJoinPayload(
                requestID: requestID,
                landType: landType,
                landInstanceId: landInstanceId,
                playerID: playerID,
                deviceID: deviceID,
                metadata: metadata
            ))
        )
    }

    /// Backward compatible join message using legacy landID format.
    ///
    /// Parses landID as "landType:instanceId" or treats entire string as landType if no colon.
    /// - Note: This is provided for backward compatibility and testing migration
    public static func join(
        requestID: String,
        landID: String,
        playerID: String?,
        deviceID: String?,
        metadata: [String: AnyCodable]?
    ) -> TransportMessage {
        // Parse landID as landType:instanceId
        let parsed = LandID(landID)
        return join(
            requestID: requestID,
            landType: parsed.landType.isEmpty ? landID : parsed.landType,
            landInstanceId: parsed.landType.isEmpty ? nil : parsed.instanceId,
            playerID: playerID,
            deviceID: deviceID,
            metadata: metadata
        )
    }

    public static func joinResponse(
        requestID: String,
        success: Bool,
        landType: String? = nil,
        landInstanceId: String? = nil,
        landID: String? = nil,
        playerID: String? = nil,
        reason: String? = nil
    ) -> TransportMessage {
        return TransportMessage(
            kind: .joinResponse,
            payload: .joinResponse(TransportJoinResponsePayload(
                requestID: requestID,
                success: success,
                landType: landType,
                landInstanceId: landInstanceId,
                landID: landID,
                playerID: playerID,
                reason: reason
            ))
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
