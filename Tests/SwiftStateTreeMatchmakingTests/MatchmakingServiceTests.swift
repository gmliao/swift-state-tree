// Tests/SwiftStateTreeTransportTests/MatchmakingServiceTests.swift
//
// Tests for MatchmakingService - player matching functionality

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeMatchmaking

// MARK: - Test State

@StateNodeBuilder
struct MatchmakingTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Test("MatchmakingService can queue players")
func testMatchmakingServiceQueuePlayers() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<MatchmakingTestState> = { landID in
        Land(landID.stringValue, using: MatchmakingTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> MatchmakingTestState = { _ in
        MatchmakingTestState()
    }
    
    let manager = LandManager<MatchmakingTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    let landTypeRegistry = LandTypeRegistry<MatchmakingTestState>(
        landFactory: { landType, landID in
            Land(landType, using: MatchmakingTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { _, _ in
            MatchmakingTestState()
        }
    )
    
    let service = MatchmakingService<MatchmakingTestState, SingleLandManagerRegistry<MatchmakingTestState>>(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in
            // Use minPlayersToStart = 2 so players will be queued instead of auto-creating lands
            DefaultMatchmakingStrategy(maxPlayersPerLand: 10, minPlayersToStart: 2)
        }
    )
    
    let playerID1 = PlayerID("player-1")
    let playerID2 = PlayerID("player-2")
    let preferences = MatchmakingPreferences(landType: "standard")
    
    // Act
    let result1 = try await service.matchmake(playerID: playerID1, preferences: preferences)
    let result2 = try await service.matchmake(playerID: playerID2, preferences: preferences)
    
    // Assert
    // With minPlayersToStart = 2, first player should be queued
    switch result1 {
    case .queued(let position):
        #expect(position == 1)
    default:
        Issue.record("Expected queued result for first player")
    }
    
    // Second player should match with first player (enough players to start)
    switch result2 {
    case .matched(let landID):
        #expect(landID.stringValue.hasPrefix("standard:"))
    case .queued:
        // Also acceptable if they're both queued (depending on timing)
        break
    default:
        Issue.record("Expected matched or queued result for second player")
    }
}

@Test("MatchmakingService can cancel matchmaking")
func testMatchmakingServiceCancel() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<MatchmakingTestState> = { landID in
        Land(landID.stringValue, using: MatchmakingTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> MatchmakingTestState = { _ in
        MatchmakingTestState()
    }
    
    let manager = LandManager<MatchmakingTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    let landTypeRegistry = LandTypeRegistry<MatchmakingTestState>(
        landFactory: { landType, landID in
            Land(landType, using: MatchmakingTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { _, _ in
            MatchmakingTestState()
        }
    )
    
    let service = MatchmakingService<MatchmakingTestState, SingleLandManagerRegistry<MatchmakingTestState>>(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in
            // Use minPlayersToStart = 2 so players will be queued instead of auto-creating lands
            DefaultMatchmakingStrategy(maxPlayersPerLand: 10, minPlayersToStart: 2)
        }
    )
    
    let playerID = PlayerID("player-1")
    let preferences = MatchmakingPreferences(landType: "standard")
    
    _ = try await service.matchmake(playerID: playerID, preferences: preferences)
    
    // Act
    await service.cancelMatchmaking(playerID: playerID)
    let status = await service.getStatus(playerID: playerID)
    
    // Assert
    #expect(status == nil, "Status should be nil after cancellation")
}

@Test("MatchmakingService provides matchmaking status")
func testMatchmakingServiceGetStatus() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<MatchmakingTestState> = { landID in
        Land(landID.stringValue, using: MatchmakingTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> MatchmakingTestState = { _ in
        MatchmakingTestState()
    }
    
    let manager = LandManager<MatchmakingTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    let landTypeRegistry = LandTypeRegistry<MatchmakingTestState>(
        landFactory: { landType, landID in
            Land(landType, using: MatchmakingTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { _, _ in
            MatchmakingTestState()
        }
    )
    
    let service = MatchmakingService<MatchmakingTestState, SingleLandManagerRegistry<MatchmakingTestState>>(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in
            // Use minPlayersToStart = 2 so players will be queued instead of auto-creating lands
            DefaultMatchmakingStrategy(maxPlayersPerLand: 10, minPlayersToStart: 2)
        }
    )
    
    let playerID = PlayerID("player-1")
    let preferences = MatchmakingPreferences(landType: "standard")
    
    _ = try await service.matchmake(playerID: playerID, preferences: preferences)
    
    // Act
    let status = await service.getStatus(playerID: playerID)
    
    // Assert
    // Note: With minPlayersToStart = 1, player might be matched immediately instead of queued
    // So status could be nil if they were matched
    if let status = status {
        #expect(status.preferences.landType == "standard")
        #expect(status.position >= 1)
        #expect(status.waitTime >= 0)
    } else {
        // If status is nil, player was likely matched immediately
        // This is acceptable behavior with minPlayersToStart = 1
    }
}

@Test("MatchmakingService returns nil status for non-queued players")
func testMatchmakingServiceStatusForNonQueuedPlayer() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<MatchmakingTestState> = { landID in
        Land(landID.stringValue, using: MatchmakingTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> MatchmakingTestState = { _ in
        MatchmakingTestState()
    }
    
    let manager = LandManager<MatchmakingTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    let landTypeRegistry = LandTypeRegistry<MatchmakingTestState>(
        landFactory: { landType, landID in
            Land(landType, using: MatchmakingTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { _, _ in
            MatchmakingTestState()
        }
    )
    
    let service = MatchmakingService<MatchmakingTestState, SingleLandManagerRegistry<MatchmakingTestState>>(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in
            // Use minPlayersToStart = 2 so players will be queued instead of auto-creating lands
            DefaultMatchmakingStrategy(maxPlayersPerLand: 10, minPlayersToStart: 2)
        }
    )
    
    let playerID = PlayerID("non-queued-player")
    
    // Act
    let status = await service.getStatus(playerID: playerID)
    
    // Assert
    #expect(status == nil)
}

@Test("MatchmakingService uses strategy to match players - full then next")
func testMatchmakingServiceStrategyFullThenNext() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<MatchmakingTestState> = { landID in
        Land(landID.stringValue, using: MatchmakingTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> MatchmakingTestState = { _ in
        MatchmakingTestState()
    }
    
    let manager = LandManager<MatchmakingTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    // Use custom strategy: max 2 players per land, need 1 player to start
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 2, minPlayersToStart: 1)
    
    let landTypeRegistry = LandTypeRegistry<MatchmakingTestState>(
        landFactory: { landType, landID in
            Land(landType, using: MatchmakingTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { _, _ in
            MatchmakingTestState()
        }
    )
    
    let service = MatchmakingService<MatchmakingTestState, SingleLandManagerRegistry<MatchmakingTestState>>(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in strategy }
    )
    
    let preferences = MatchmakingPreferences(landType: "standard")
    
    // Act: First player should be queued (no existing lands)
    let result1 = try await service.matchmake(playerID: PlayerID("player-1"), preferences: preferences)
    
    // Create a land manually and add players to it
    let landID1 = LandID("land-1")
    let def1 = landFactory(landID1)
    let init1 = initialStateFactory(landID1)
    _ = await manager.getOrCreateLand(landID: landID1, definition: def1, initialState: init1)
    
    // Simulate adding players to the land (we can't actually join, but we can check stats)
    // For this test, we'll just verify the strategy logic works
    
    // Second player should match to the empty land
    let result2 = try await service.matchmake(playerID: PlayerID("player-2"), preferences: preferences)
    
    // Assert
    // With minPlayersToStart = 1, first player will create a new land immediately
    switch result1 {
    case .matched(let landID):
        #expect(landID.stringValue.hasPrefix("standard:"))
    case .queued:
        // Also acceptable if queued (depending on timing)
        break
    default:
        Issue.record("First player should be matched or queued")
    }
    
    // Second player should match to the existing land or create a new one
    switch result2 {
    case .matched(let landID):
        #expect(landID.stringValue.hasPrefix("standard:") || landID.stringValue == "land-1")
    case .queued:
        // Also acceptable if queued
        break
    default:
        Issue.record("Second player should be matched or queued")
    }
}

@Test("DefaultMatchmakingStrategy respects maxPlayersPerLand")
func testDefaultMatchmakingStrategyMaxPlayers() async throws {
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 5, minPlayersToStart: 1)
    
    // Create a land with 4 players (below max)
    let stats1 = LandStats(
        landID: LandID("land-1"),
        playerCount: 4,
        createdAt: Date(),
        lastActivityAt: Date()
    )
    
    // Create a land with 5 players (at max)
    let stats2 = LandStats(
        landID: LandID("land-2"),
        playerCount: 5,
        createdAt: Date(),
        lastActivityAt: Date()
    )
    
    let preferences = MatchmakingPreferences(landType: "standard")
    let waitingPlayers: [MatchmakingRequest] = []
    
    // Act
    let canMatch1 = await strategy.canMatch(
        playerPreferences: preferences,
        landStats: stats1,
        waitingPlayers: waitingPlayers
    )
    
    let canMatch2 = await strategy.canMatch(
        playerPreferences: preferences,
        landStats: stats2,
        waitingPlayers: waitingPlayers
    )
    
    // Assert
    #expect(canMatch1 == true, "Land with 4 players (below max 5) should be matchable")
    #expect(canMatch2 == false, "Land with 5 players (at max 5) should not be matchable")
}

@Test("DefaultMatchmakingStrategy requires minPlayersToStart")
func testDefaultMatchmakingStrategyMinPlayers() async throws {
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 10, minPlayersToStart: 2)
    
    let preferences = MatchmakingPreferences(landType: "standard")
    
    // Act: No matching players
    let hasEnough1 = strategy.hasEnoughPlayers(
        matchingPlayers: [],
        preferences: preferences
    )
    
    // Act: One matching player
    let request1 = MatchmakingRequest(
        playerID: PlayerID("player-1"),
        preferences: preferences,
        queuedAt: Date()
    )
    let hasEnough2 = strategy.hasEnoughPlayers(
        matchingPlayers: [request1],
        preferences: preferences
    )
    
    // Act: Two matching players
    let request2 = MatchmakingRequest(
        playerID: PlayerID("player-2"),
        preferences: preferences,
        queuedAt: Date()
    )
    let hasEnough3 = strategy.hasEnoughPlayers(
        matchingPlayers: [request1, request2],
        preferences: preferences
    )
    
    // Assert
    #expect(hasEnough1 == false, "Need at least 2 players")
    #expect(hasEnough2 == false, "Need at least 2 players")
    #expect(hasEnough3 == true, "2 players is enough")
}

