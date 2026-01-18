import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import Logging

/// Container for lobby lands (special lands for matchmaking and room management).
///
/// Wraps a `LandContainer` and provides lobby-specific functionality:
/// - Matchmaking requests (automatic matching via MatchmakingService)
/// - Room creation (client can freely create rooms)
/// - Room joining (manual room selection)
/// - Room list tracking (similar to Colyseus LobbyRoom)
///
/// Lobbies are special lands managed by `LandManager`, identified by landID
/// naming convention (e.g., `lobby-asia`, `lobby-europe`).
public struct LobbyContainer<State: StateNodeProtocol, Registry: LandManagerRegistry>: Sendable where Registry.State == State {
    public let container: LandContainer<State>
    private let matchmakingService: MatchmakingService<State, Registry>
    private let landManagerRegistry: Registry
    private let landTypeRegistry: LandTypeRegistry<State>
    private let logger: Logger
    
    /// Initialize a LobbyContainer.
    ///
    /// - Parameters:
    ///   - container: The underlying LandContainer for this lobby.
    ///   - matchmakingService: The matchmaking service for automatic matching.
    ///   - landManagerRegistry: The land manager registry for creating/querying lands.
    ///   - landTypeRegistry: The land type registry for land configurations.
    ///   - logger: Optional logger instance.
    public init(
        container: LandContainer<State>,
        matchmakingService: MatchmakingService<State, Registry>,
        landManagerRegistry: Registry,
        landTypeRegistry: LandTypeRegistry<State>,
        logger: Logger? = nil
    ) {
        self.container = container
        self.matchmakingService = matchmakingService
        self.landManagerRegistry = landManagerRegistry
        self.landTypeRegistry = landTypeRegistry
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.lobby",
            scope: "LobbyContainer"
        )
    }
    
    /// Request matchmaking for a player (automatic matching).
    ///
    /// - Parameters:
    ///   - playerID: The player requesting matchmaking.
    ///   - preferences: Matchmaking preferences (includes landType).
    /// - Returns: MatchmakingResult indicating success, queued, or failure.
    public func requestMatchmaking(
        playerID: PlayerID,
        preferences: MatchmakingPreferences
    ) async throws -> MatchmakingResult {
        let result = try await matchmakingService.matchmake(
            playerID: playerID,
            preferences: preferences
        )
        
        // Send result to player via Event
        await sendMatchmakingResult(playerID: playerID, result: result)
        
        return result
    }
    
    /// Create a new game room (client can freely create).
    ///
    /// - Parameters:
    ///   - playerID: The player creating the room.
    ///   - landType: The type of land to create.
    ///   - roomName: Optional room name.
    ///   - maxPlayers: Optional maximum players.
    /// - Returns: The LandID of the created room.
    /// - Throws: Error if room creation fails.
    public func createRoom(
        playerID: PlayerID,
        landType: String,
        roomName: String? = nil,
        maxPlayers: Int? = nil
    ) async throws -> LandID {
        // Generate unique landID using structured format (landType:instanceId)
        let landID = LandID.generate(landType: landType)
        
        // Get LandDefinition and initial state from registry
        let definition = landTypeRegistry.getLandDefinition(
            landType: landType,
            landID: landID
        )
        let initialState = landTypeRegistry.initialStateFactory(landType, landID)
        
        // Create the land
        _ = await landManagerRegistry.createLand(
            landID: landID,
            definition: definition,
            initialState: initialState,
            metadata: [:]
        )
        
        logger.info("Room created by player", metadata: [
            "playerID": .string(playerID.rawValue),
            "landID": .string(landID.stringValue),
            "landType": .string(landType),
            "roomName": .string(roomName ?? "unnamed")
        ])
        
        // Update room list and notify all lobby players
        await updateAndNotifyRoomList()
        
        return landID
    }
    
    /// Manually join a specific room.
    ///
    /// - Parameters:
    ///   - playerID: The player joining the room.
    ///   - landID: The LandID of the room to join.
    /// - Returns: `true` if the room exists and can be joined, `false` otherwise.
    public func joinRoom(
        playerID: PlayerID,
        landID: LandID
    ) async -> Bool {
        // Check if room exists
        guard let _ = await landManagerRegistry.getLand(landID: landID) else {
            logger.warning("Attempted to join non-existent room", metadata: [
                "playerID": .string(playerID.rawValue),
                "landID": .string(landID.stringValue)
            ])
            return false
        }
        
        logger.info("Player requested to join room", metadata: [
            "playerID": .string(playerID.rawValue),
            "landID": .string(landID.stringValue)
        ])
        
        // Note: Actual joining happens when player connects to the room's WebSocket
        // This method just validates that the room exists
        return true
    }
    
    /// Update room list by querying all available game rooms.
    ///
    /// Filters out lobbies and returns only game rooms.
    /// - Returns: Array of AvailableRoom information.
    public func updateRoomList() async -> [AvailableRoom] {
        let allLands = await landManagerRegistry.listAllLands()
        var availableRooms: [AvailableRoom] = []
        
        for landID in allLands {
            // Skip lobbies (identified by naming convention)
            if isLobby(landID: landID) {
                continue
            }
            
            // Get room stats
            if let stats = await landManagerRegistry.getLandStats(landID: landID) {
                // Try to determine landType from landID or stats
                // For now, extract from landID (format: "landType-uuid")
                let landType = extractLandType(from: landID)
                
                let room = AvailableRoom(
                    landID: landID,
                    landType: landType,
                    playerCount: stats.playerCount,
                    maxPlayers: nil, // Could be stored in state or metadata
                    roomName: nil,   // Could be stored in state or metadata
                    createdAt: stats.createdAt
                )
                availableRooms.append(room)
            }
        }
        
        return availableRooms
    }
    
    /// Update room list and notify all lobby players of changes.
    ///
    /// Compares current room list with previous state and sends appropriate events.
    public func updateAndNotifyRoomList() async {
        let currentRooms = await updateRoomList()
        
        // For now, send full room list update
        // In the future, could track previous state and send incremental updates
        // by comparing with container.currentState() to detect changes
        let event = RoomListEvent.roomList(rooms: currentRooms)
        await sendRoomListEvent(event, to: .all)
    }
    
    /// Send matchmaking result to a player via Event.
    ///
    /// - Parameters:
    ///   - playerID: The player to send the result to.
    ///   - result: The matchmaking result.
    private func sendMatchmakingResult(
        playerID: PlayerID,
        result: MatchmakingResult
    ) async {
        let event: MatchmakingEvent
        switch result {
        case .matched(let landID):
            event = .matched(landID: landID)
        case .queued(let position):
            event = .queued(position: position)
        case .failed(let reason):
            event = .failed(reason: reason)
        }
        
        await sendMatchmakingEvent(event, to: .player(playerID))
    }
    
    /// Send matchmaking event to target.
    private func sendMatchmakingEvent(
        _ event: MatchmakingEvent,
        to target: SwiftStateTree.EventTarget
    ) async {
        let anyEvent = AnyServerEvent(event)
        await container.transportAdapter.sendEvent(anyEvent, to: target)
    }
    
    /// Send room list event to target.
    private func sendRoomListEvent(
        _ event: RoomListEvent,
        to target: SwiftStateTree.EventTarget
    ) async {
        let anyEvent = AnyServerEvent(event)
        await container.transportAdapter.sendEvent(anyEvent, to: target)
    }
    
    /// Check if a landID represents a lobby.
    ///
    /// Uses landType property: landType starting with "lobby"
    private func isLobby(landID: LandID) -> Bool {
        return landID.landType.hasPrefix("lobby")
    }
    
    /// Extract landType from landID.
    ///
    /// Uses the structured landType property.
    private func extractLandType(from landID: LandID) -> String {
        return landID.landType
    }
}

