import Foundation

/// Error code identifiers for different error types.
public enum ErrorCode: String, Codable, Sendable {
    // Join errors
    case joinSessionNotConnected = "JOIN_SESSION_NOT_CONNECTED"
    case joinAlreadyJoined = "JOIN_ALREADY_JOINED"
    case joinLandIDMismatch = "JOIN_LAND_ID_MISMATCH"
    case joinDenied = "JOIN_DENIED"
    case joinRoomFull = "JOIN_ROOM_FULL"
    case joinRoomNotFound = "JOIN_ROOM_NOT_FOUND"
    case joinLandTypeNotFound = "JOIN_LAND_TYPE_NOT_FOUND"
    
    // Action errors
    case actionNotRegistered = "ACTION_NOT_REGISTERED"
    case actionInvalidPayload = "ACTION_INVALID_PAYLOAD"
    case actionHandlerError = "ACTION_HANDLER_ERROR"
    
    // Message format errors
    case invalidMessageFormat = "INVALID_MESSAGE_FORMAT"
    case invalidJSON = "INVALID_JSON"
    case missingRequiredField = "MISSING_REQUIRED_FIELD"
    
    // Event errors
    case eventNotRegistered = "EVENT_NOT_REGISTERED"
    case eventInvalidPayload = "EVENT_INVALID_PAYLOAD"
    case eventHandlerError = "EVENT_HANDLER_ERROR"
}

/// Unified error payload structure for all transport errors.
public struct ErrorPayload: Codable, Sendable {
    /// Error code identifier.
    public let code: String
    
    /// Human-readable error message.
    public let message: String
    
    /// Optional additional details for debugging.
    public let details: [String: AnyCodable]?
    
    public init(code: String, message: String, details: [String: AnyCodable]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
    
    /// Convenience initializer using ErrorCode enum.
    public init(code: ErrorCode, message: String, details: [String: AnyCodable]? = nil) {
        self.code = code.rawValue
        self.message = message
        self.details = details
    }
}


