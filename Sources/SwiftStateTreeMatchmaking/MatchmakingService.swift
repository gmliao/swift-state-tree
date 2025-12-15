import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import Logging

// Note: MatchmakingStrategy protocol is in SwiftStateTreeTransport (MatchmakingStrategyProtocol.swift)
// MatchmakingPreferences and MatchmakingRequest are in SwiftStateTreeMatchmaking (MatchmakingTypes.swift)

/// Matchmaking service for user/player matching and land assignment.
///
/// Independent from land management, focuses on matching logic.
/// Uses LandManagerRegistry to interact with land management (supports both single-process
/// and future multi-process distributed architectures).
/// Uses LandTypeRegistry to manage different land types, each with its own matching strategy.
///
/// Each land type has its own independent matching queue and strategy, allowing different
/// matching rules for different types of lands (e.g., collaboration rooms, chat channels, games).
///
/// Implements MatchmakingServiceProtocol for future distributed actor support.
public actor MatchmakingService<State: StateNodeProtocol, Registry: LandManagerRegistry>: MatchmakingServiceProtocol where Registry.State == State {
    private let registry: Registry
    private let landTypeRegistry: LandTypeRegistry<State>
    
    /// Waiting users/players grouped by land type.
    /// Each land type has its own independent queue.
    private var waitingPlayersByLandType: [String: [PlayerID: MatchmakingRequest]] = [:]
    
    private let logger: Logger
    
    /// Factory for creating matchmaking strategies for different land types.
    /// Each land type can have its own matching rules.
    private let strategyFactory: @Sendable (String) -> any MatchmakingStrategy
    
    /// Initialize MatchmakingService.
    ///
    /// - Parameters:
    ///   - registry: The land manager registry to use for creating/querying lands.
    ///   - landTypeRegistry: Registry for land types and their configurations.
    ///   - strategyFactory: Factory function that returns a MatchmakingStrategy for a given landType.
    ///   - logger: Optional logger instance.
    public init(
        registry: Registry,
        landTypeRegistry: LandTypeRegistry<State>,
        strategyFactory: @escaping @Sendable (String) -> any MatchmakingStrategy,
        logger: Logger? = nil
    ) {
        self.registry = registry
        self.landTypeRegistry = landTypeRegistry
        self.strategyFactory = strategyFactory
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.matchmaking",
            scope: "MatchmakingService"
        )
    }
    
    /// Request matchmaking for a user/player.
    ///
    /// - Parameters:
    ///   - playerID: The user/player requesting matchmaking.
    ///   - preferences: Matchmaking preferences (includes landType).
    /// - Returns: MatchmakingResult indicating success, queued, or failure.
    public func matchmake(
        playerID: PlayerID,
        preferences: MatchmakingPreferences
    ) async throws -> MatchmakingResult {
        let landType = preferences.landType
        
        // Get strategy for this land type
        let strategy = strategyFactory(landType)
        
        // Get or create queue for this land type
        if waitingPlayersByLandType[landType] == nil {
            waitingPlayersByLandType[landType] = [:]
        }
        guard var waitingPlayers = waitingPlayersByLandType[landType] else {
            return .failed(reason: "Invalid land type: \(landType)")
        }
        
        // Cancel any existing matchmaking for this player
        waitingPlayers.removeValue(forKey: playerID)
        
        // Step 1: Try to find an existing suitable land for this land type
        let allLands = await registry.listAllLands()
        let waitingPlayersList = Array(waitingPlayers.values)
        
        for landID in allLands {
            if let stats = await registry.getLandStats(landID: landID) {
                // Use this land type's strategy to check if can match
                let canMatch = await strategy.canMatch(
                    playerPreferences: preferences,
                    landStats: stats,
                    waitingPlayers: waitingPlayersList
                )
                
                if canMatch {
                    // Check if there are other waiting players with same land type
                    let matchingPlayers = waitingPlayersList.filter { request in
                        request.preferences.landType == landType
                    }
                    
                    // Use strategy to check if we have enough players
                    if strategy.hasEnoughPlayers(
                        matchingPlayers: matchingPlayers,
                        preferences: preferences
                    ) {
                        // Match found!
                        waitingPlayersByLandType[landType] = waitingPlayers
                        logger.info("Player matched to land", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "landID": .string(landID.stringValue),
                            "landType": .string(landType)
                        ])
                        return .matched(landID: landID)
                    }
                }
                // If this land is full or doesn't match, continue to next land
            }
        }
        
        // Step 2: No existing land found, check if we can create a new one
        let matchingPlayers = waitingPlayersList.filter { request in
            request.preferences.landType == landType
        }
        
        // Include current player
        let allMatchingPlayers = matchingPlayers + [MatchmakingRequest(
            playerID: playerID,
            preferences: preferences,
            queuedAt: Date()
        )]
        
        if strategy.hasEnoughPlayers(
            matchingPlayers: allMatchingPlayers,
            preferences: preferences
        ) {
            // Create new land for this land type using structured LandID format
            let newLandID = LandID.generate(landType: landType)
            
            // Use landTypeRegistry to get the correct LandDefinition for this landType
            let definition = landTypeRegistry.getLandDefinition(
                landType: landType,
                landID: newLandID
            )
            let initialState = landTypeRegistry.initialStateFactory(landType, newLandID)
            
            _ = await registry.createLand(
                landID: newLandID,
                definition: definition,
                initialState: initialState
            )
            
            // Remove matched players from queue
            for request in allMatchingPlayers {
                waitingPlayers.removeValue(forKey: request.playerID)
            }
            waitingPlayersByLandType[landType] = waitingPlayers
            
            logger.info("Created new land for land type", metadata: [
                "landType": .string(landType),
                "landID": .string(newLandID.stringValue),
                "playerCount": .string("\(allMatchingPlayers.count)")
            ])
            
            return .matched(landID: newLandID)
        }
        
        // Step 3: Not enough players, add to queue
        let position = waitingPlayers.count + 1
        let request = MatchmakingRequest(
            playerID: playerID,
            preferences: preferences,
            queuedAt: Date()
        )
        waitingPlayers[playerID] = request
        waitingPlayersByLandType[landType] = waitingPlayers
        
        logger.info("Player queued for matchmaking", metadata: [
            "playerID": .string(playerID.rawValue),
            "landType": .string(landType),
            "position": .string("\(position)")
        ])
        
        return .queued(position: position)
    }
    
    /// Cancel matchmaking request for a user/player.
    ///
    /// - Parameter playerID: The user/player to cancel matchmaking for.
    public func cancelMatchmaking(playerID: PlayerID) async {
        // Search through all land type queues
        for (landType, var waitingPlayers) in waitingPlayersByLandType {
            if waitingPlayers.removeValue(forKey: playerID) != nil {
                waitingPlayersByLandType[landType] = waitingPlayers
                logger.info("Matchmaking cancelled", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "landType": .string(landType)
                ])
                return
            }
        }
    }
    
    /// Get matchmaking status for a user/player.
    ///
    /// - Parameter playerID: The user/player to get status for.
    /// - Returns: MatchmakingStatus if player is in queue, nil otherwise.
    public func getStatus(playerID: PlayerID) async -> MatchmakingStatus? {
        // Search through all land type queues
        for (_, waitingPlayers) in waitingPlayersByLandType {
            if let request = waitingPlayers[playerID] {
                // Calculate position based on queue time (earlier = lower position number)
                let position = waitingPlayers.values
                    .filter { $0.queuedAt <= request.queuedAt }
                    .count
                
                let waitTime = Date().timeIntervalSince(request.queuedAt)
                
                return MatchmakingStatus(
                    position: position,
                    waitTime: waitTime,
                    preferences: request.preferences
                )
            }
        }
        
        return nil
    }
}

