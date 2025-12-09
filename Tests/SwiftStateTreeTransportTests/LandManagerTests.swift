// Tests/SwiftStateTreeTransportTests/LandManagerTests.swift
//
// Tests for LandManager - multi-room management functionality

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct ManagerTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var ticks: Int = 0
}

// MARK: - Tests

@Test("LandManager can create and retrieve lands")
func testLandManagerCreateAndRetrieve() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<ManagerTestState> = { landID in
        Land(landID.stringValue, using: ManagerTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> ManagerTestState = { _ in
        ManagerTestState()
    }
    
    let manager = LandManager<ManagerTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let landID1 = LandID("land-1")
    let landID2 = LandID("land-2")
    
    // Act
    let definition1 = landFactory(landID1)
    let initialState1 = initialStateFactory(landID1)
    let definition2 = landFactory(landID2)
    let initialState2 = initialStateFactory(landID2)
    
    let container1 = await manager.getOrCreateLand(landID: landID1, definition: definition1, initialState: initialState1)
    let container2 = await manager.getOrCreateLand(landID: landID2, definition: definition2, initialState: initialState2)
    let retrieved1 = await manager.getLand(landID: landID1)
    let retrieved2 = await manager.getLand(landID: landID2)
    let nonExistent = await manager.getLand(landID: LandID("non-existent"))
    
    // Assert
    #expect(container1.landID == landID1)
    #expect(container2.landID == landID2)
    #expect(retrieved1?.landID == landID1)
    #expect(retrieved2?.landID == landID2)
    #expect(nonExistent == nil)
}

@Test("LandManager lists all active lands")
func testLandManagerListLands() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<ManagerTestState> = { landID in
        Land(landID.stringValue, using: ManagerTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> ManagerTestState = { _ in
        ManagerTestState()
    }
    
    let manager = LandManager<ManagerTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    // Act
    let emptyList = await manager.listLands()
    let landID1 = LandID("land-1")
    let landID2 = LandID("land-2")
    let landID3 = LandID("land-3")
    
    let def1 = landFactory(landID1)
    let init1 = initialStateFactory(landID1)
    let def2 = landFactory(landID2)
    let init2 = initialStateFactory(landID2)
    let def3 = landFactory(landID3)
    let init3 = initialStateFactory(landID3)
    
    _ = await manager.getOrCreateLand(landID: landID1, definition: def1, initialState: init1)
    _ = await manager.getOrCreateLand(landID: landID2, definition: def2, initialState: init2)
    _ = await manager.getOrCreateLand(landID: landID3, definition: def3, initialState: init3)
    
    let allLands = await manager.listLands()
    
    // Assert
    #expect(emptyList.isEmpty)
    #expect(allLands.count == 3)
    #expect(allLands.contains(landID1))
    #expect(allLands.contains(landID2))
    #expect(allLands.contains(landID3))
}

@Test("LandManager can remove lands")
func testLandManagerRemoveLand() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<ManagerTestState> = { landID in
        Land(landID.stringValue, using: ManagerTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> ManagerTestState = { _ in
        ManagerTestState()
    }
    
    let manager = LandManager<ManagerTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let landID1 = LandID("land-1")
    let landID2 = LandID("land-2")
    
    let def1 = landFactory(landID1)
    let init1 = initialStateFactory(landID1)
    let def2 = landFactory(landID2)
    let init2 = initialStateFactory(landID2)
    
    _ = await manager.getOrCreateLand(landID: landID1, definition: def1, initialState: init1)
    _ = await manager.getOrCreateLand(landID: landID2, definition: def2, initialState: init2)
    
    // Act
    await manager.removeLand(landID: landID1)
    let remainingLands = await manager.listLands()
    let retrieved1 = await manager.getLand(landID: landID1)
    let retrieved2 = await manager.getLand(landID: landID2)
    
    // Assert
    #expect(remainingLands.count == 1)
    #expect(remainingLands.contains(landID2))
    #expect(retrieved1 == nil)
    #expect(retrieved2 != nil)
}

@Test("LandManager provides land statistics")
func testLandManagerGetStats() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<ManagerTestState> = { landID in
        Land(landID.stringValue, using: ManagerTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> ManagerTestState = { _ in
        ManagerTestState()
    }
    
    let manager = LandManager<ManagerTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let landID = LandID("land-1")
    let definition = landFactory(landID)
    let initialState = initialStateFactory(landID)
    let container = await manager.getOrCreateLand(landID: landID, definition: definition, initialState: initialState)
    
    // Act
    let stats = await manager.getLandStats(landID: landID)
    let nonExistentStats = await manager.getLandStats(landID: LandID("non-existent"))
    
    // Assert
    #expect(stats != nil)
    #expect(stats?.landID == landID)
    #expect(stats?.playerCount == 0) // No players joined yet
    #expect(nonExistentStats == nil)
}

@Test("LandManager getOrCreateLand returns same container for same landID")
func testLandManagerGetOrCreateReturnsSameContainer() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<ManagerTestState> = { landID in
        Land(landID.stringValue, using: ManagerTestState.self) {
            Rules {}
        }
    }
    
    let initialStateFactory: @Sendable (LandID) -> ManagerTestState = { _ in
        ManagerTestState()
    }
    
    let manager = LandManager<ManagerTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )
    
    let landID = LandID("land-1")
    
    // Act
    let definition = landFactory(landID)
    let initialState = initialStateFactory(landID)
    let container1 = await manager.getOrCreateLand(landID: landID, definition: definition, initialState: initialState)
    let container2 = await manager.getOrCreateLand(landID: landID, definition: definition, initialState: initialState)
    
    // Assert - Should return the same container (same landID)
    #expect(container1.landID == container2.landID)
    #expect(container1.landID == landID)
}

