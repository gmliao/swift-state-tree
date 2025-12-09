// Tests/SwiftStateTreeTransportTests/LandManagerRegistryTests.swift
//
// Tests for LandManagerRegistry - land manager registry functionality

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct RegistryTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Test("SingleLandManagerRegistry delegates to underlying LandManager")
func testSingleLandManagerRegistryDelegates() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<RegistryTestState> = { landID in
        Land(landID.stringValue, using: RegistryTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> RegistryTestState = { _ in
        RegistryTestState()
    }
    
    let manager = LandManager<RegistryTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    // Act & Assert
    // Test listAllLands
    let initialLands = await registry.listAllLands()
    #expect(initialLands.isEmpty)
    
    // Test createLand
    let landID1 = LandID("test-land-1")
    let definition1 = landFactory(landID1)
    let initialState1 = initialStateFactory(landID1)
    
    let container1 = await registry.createLand(
        landID: landID1,
        definition: definition1,
        initialState: initialState1
    )
    #expect(container1.landID == landID1)
    
    // Test listAllLands after creation
    let landsAfterCreate = await registry.listAllLands()
    #expect(landsAfterCreate.count == 1)
    #expect(landsAfterCreate.contains(landID1))
    
    // Test getLand
    let retrievedContainer = await registry.getLand(landID: landID1)
    #expect(retrievedContainer != nil)
    #expect(retrievedContainer?.landID == landID1)
    
    // Test getLandStats
    let stats = await registry.getLandStats(landID: landID1)
    #expect(stats != nil)
    #expect(stats?.landID == landID1)
    #expect(stats?.playerCount == 0)
    
    // Test getLand for non-existent land
    let nonExistent = await registry.getLand(landID: LandID("non-existent"))
    #expect(nonExistent == nil)
    
    // Test getLandStats for non-existent land
    let nonExistentStats = await registry.getLandStats(landID: LandID("non-existent"))
    #expect(nonExistentStats == nil)
}

@Test("SingleLandManagerRegistry creates multiple lands")
func testSingleLandManagerRegistryMultipleLands() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<RegistryTestState> = { landID in
        Land(landID.stringValue, using: RegistryTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> RegistryTestState = { _ in
        RegistryTestState()
    }
    
    let manager = LandManager<RegistryTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    // Act - Create multiple lands
    let landID1 = LandID("land-1")
    let landID2 = LandID("land-2")
    let landID3 = LandID("land-3")
    
    let container1 = await registry.createLand(
        landID: landID1,
        definition: landFactory(landID1),
        initialState: initialStateFactory(landID1)
    )
    
    let container2 = await registry.createLand(
        landID: landID2,
        definition: landFactory(landID2),
        initialState: initialStateFactory(landID2)
    )
    
    let container3 = await registry.createLand(
        landID: landID3,
        definition: landFactory(landID3),
        initialState: initialStateFactory(landID3)
    )
    
    // Assert
    #expect(container1.landID == landID1)
    #expect(container2.landID == landID2)
    #expect(container3.landID == landID3)
    
    let allLands = await registry.listAllLands()
    #expect(allLands.count == 3)
    #expect(allLands.contains(landID1))
    #expect(allLands.contains(landID2))
    #expect(allLands.contains(landID3))
}

@Test("SingleLandManagerRegistry returns same container for existing land")
func testSingleLandManagerRegistryReusesExistingLand() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<RegistryTestState> = { landID in
        Land(landID.stringValue, using: RegistryTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> RegistryTestState = { _ in
        RegistryTestState()
    }
    
    let manager = LandManager<RegistryTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let registry = SingleLandManagerRegistry(landManager: manager)
    
    // Act - Create land first time
    let landID = LandID("test-land")
    let container1 = await registry.createLand(
        landID: landID,
        definition: landFactory(landID),
        initialState: initialStateFactory(landID)
    )
    
    // Create same land again (should return existing)
    let container2 = await registry.createLand(
        landID: landID,
        definition: landFactory(landID),
        initialState: initialStateFactory(landID)
    )
    
    // Assert - Should return same container
    #expect(container1.landID == container2.landID)
    
    // Verify only one land exists
    let allLands = await registry.listAllLands()
    #expect(allLands.count == 1)
    #expect(allLands.contains(landID))
}

