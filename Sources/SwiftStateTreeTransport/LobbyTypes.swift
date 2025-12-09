import Foundation
import SwiftStateTree

// MARK: - Lobby State

/// Base state for lobby lands.
///
/// Provides foundation for lobby functionality including matchmaking status,
/// waiting players list, and available rooms list.
/// Users can extend this state to add custom fields.
@StateNodeBuilder
public struct LobbyState: StateNodeProtocol {
    /// Matchmaking status for each player (per-player slice).
    @Sync(.perPlayerSlice())
    public var matchmakingStatus: [PlayerID: MatchmakingStatus] = [:]
    
    /// List of waiting players (optional, for display purposes).
    @Sync(.broadcast)
    public var waitingPlayers: [PlayerID: PlayerInfo] = [:]
    
    /// List of available game rooms (tracked and synced to all players).
    @Sync(.broadcast)
    public var availableRooms: [LandID: AvailableRoom] = [:]
    
    public init() {}
}

/// Information about a player in the lobby.
public struct PlayerInfo: Codable, Sendable {
    public let playerID: PlayerID
    public let displayName: String?
    public let level: Int?
    public let region: String?
    
    public init(
        playerID: PlayerID,
        displayName: String? = nil,
        level: Int? = nil,
        region: String? = nil
    ) {
        self.playerID = playerID
        self.displayName = displayName
        self.level = level
        self.region = region
    }
}

/// Information about an available game room.
public struct AvailableRoom: Codable, Sendable {
    public let landID: LandID
    public let landType: String
    public let playerCount: Int
    public let maxPlayers: Int?
    public let roomName: String?
    public let createdAt: Date
    
    public init(
        landID: LandID,
        landType: String,
        playerCount: Int,
        maxPlayers: Int? = nil,
        roomName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.landID = landID
        self.landType = landType
        self.playerCount = playerCount
        self.maxPlayers = maxPlayers
        self.roomName = roomName
        self.createdAt = createdAt
    }
}

// MARK: - Lobby Actions

/// Response for matchmaking request.
public struct MatchmakingResponse: ResponsePayload, Codable, Sendable {
    public let result: MatchmakingResult
    
    public init(result: MatchmakingResult) {
        self.result = result
    }
    
    public static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
}

/// Action to request matchmaking (automatic matching).
public struct RequestMatchmakingAction: ActionPayload, Codable, Sendable {
    public typealias Response = MatchmakingResponse
    
    public let preferences: MatchmakingPreferences
    
    public init(preferences: MatchmakingPreferences) {
        self.preferences = preferences
    }
    
    public static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
    
    public static func getResponseType() -> Any.Type {
        return MatchmakingResponse.self
    }
}

/// Response for room creation.
public struct CreateRoomResponse: ResponsePayload, Codable, Sendable {
    public let landID: LandID
    public let success: Bool
    public let message: String?
    
    public init(landID: LandID, success: Bool, message: String? = nil) {
        self.landID = landID
        self.success = success
        self.message = message
    }
    
    public static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
}

/// Action to create a new game room (client can freely create).
public struct CreateRoomAction: ActionPayload, Codable, Sendable {
    public typealias Response = CreateRoomResponse
    
    public let landType: String
    public let roomName: String?
    public let maxPlayers: Int?
    
    public init(
        landType: String,
        roomName: String? = nil,
        maxPlayers: Int? = nil
    ) {
        self.landType = landType
        self.roomName = roomName
        self.maxPlayers = maxPlayers
    }
    
    public static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
    
    public static func getResponseType() -> Any.Type {
        return CreateRoomResponse.self
    }
}

/// Response for room join.
public struct JoinRoomResponse: ResponsePayload, Codable, Sendable {
    public let success: Bool
    public let message: String?
    
    public init(success: Bool, message: String? = nil) {
        self.success = success
        self.message = message
    }
    
    public static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
}

/// Action to manually join a specific room.
public struct JoinRoomAction: ActionPayload, Codable, Sendable {
    public typealias Response = JoinRoomResponse
    
    public let landID: LandID
    
    public init(landID: LandID) {
        self.landID = landID
    }
    
    public static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
    
    public static func getResponseType() -> Any.Type {
        return JoinRoomResponse.self
    }
}

// MARK: - Lobby Events

/// Event for matchmaking results.
public enum MatchmakingEvent: ServerEventPayload, Codable, Sendable {
    /// Successfully matched to a land.
    case matched(landID: LandID)
    
    /// Queued for matching (with position in queue).
    case queued(position: Int)
    
    /// Matchmaking failed with reason.
    case failed(reason: String)
}

/// Event for room list changes (similar to Colyseus LobbyRoom).
public enum RoomListEvent: ServerEventPayload, Codable, Sendable {
    /// A new room was added to the list.
    case roomAdded(room: AvailableRoom)
    
    /// A room was removed from the list.
    case roomRemoved(landID: LandID)
    
    /// A room was updated (e.g., player count changed).
    case roomUpdated(room: AvailableRoom)
    
    /// Full room list update (sent when player first joins lobby).
    case roomList(rooms: [AvailableRoom])
}

