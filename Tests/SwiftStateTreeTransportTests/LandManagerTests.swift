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
    _ = await manager.getOrCreateLand(landID: landID, definition: definition, initialState: initialState)

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


// MARK: - Test State with Counter

@StateNodeBuilder
struct CounterTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    public init() {}
}

@Payload
struct IncrementTestAction: ActionPayload {
    public typealias Response = IncrementTestResponse
    let amount: Int

    public init(amount: Int = 1) {
        self.amount = amount
    }
}

@Payload
struct IncrementTestResponse: ResponsePayload {
    let newCount: Int

    public init(newCount: Int) {
        self.newCount = newCount
    }
}

@Test("LandManager automatically removes land when destroyed")
func testLandManagerAutoRemovesDestroyedLand() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<CounterTestState> = { landID in
        Land(landID.stringValue, using: CounterTestState.self) {
            Lifetime {
                DestroyWhenEmpty(after: .milliseconds(50)) { (_: inout CounterTestState, _: LandContext) in
                    // Empty handler
                }
            }
            Rules {}
        }
    }

    let initialStateFactory: @Sendable (LandID) -> CounterTestState = { _ in
        CounterTestState()
    }

    let manager = LandManager<CounterTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )

    let landID = LandID("auto-remove-test")
    let playerID1 = PlayerID("player-1")
    let clientID1 = ClientID("client-1")
    let sessionID1 = SessionID("session-1")

    // Act - Create land and join player
    let definition = landFactory(landID)
    let initialState = initialStateFactory(landID)
    let container = await manager.getOrCreateLand(landID: landID, definition: definition, initialState: initialState)

    // Verify land exists
    let landBeforeDestroy = await manager.getLand(landID: landID)
    let landsBeforeDestroy = await manager.listLands()
    #expect(landBeforeDestroy != nil, "Land should exist before destroy")
    #expect(landsBeforeDestroy.contains(landID), "Land should be in list before destroy")

    // Join player
    _ = try await container.keeper.join(playerID: playerID1, clientID: clientID1, sessionID: sessionID1)

    // Leave player to trigger destroy
    try await container.keeper.leave(playerID: playerID1, clientID: clientID1)

    // Wait for destroy to complete (AfterFinalize is the last handler, then onLandDestroyed is called)
    try await Task.sleep(for: .milliseconds(150))

    // Assert - Land should be automatically removed from LandManager
    let landAfterDestroy = await manager.getLand(landID: landID)
    let landsAfterDestroy = await manager.listLands()
    #expect(landAfterDestroy == nil, "Land should be automatically removed from LandManager after destroy")
    #expect(!landsAfterDestroy.contains(landID), "Land should not be in list after destroy")
}

@Test("LandManager recreates land with fresh state when destroyed land is removed")
func testLandManagerRecreatesDestroyedLandWithFreshState() async throws {
    // Arrange
    let landFactory: @Sendable (LandID) -> LandDefinition<CounterTestState> = { landID in
        Land(landID.stringValue, using: CounterTestState.self) {
            Lifetime {
                DestroyWhenEmpty(after: .milliseconds(50)) { (_: inout CounterTestState, _: LandContext) in
                    // Empty handler
                }
            }
            Rules {
                HandleAction(IncrementTestAction.self) { (state: inout CounterTestState, action: IncrementTestAction, _: LandContext) in
                    state.count += action.amount
                    return IncrementTestResponse(newCount: state.count)
                }
            }
        }
    }

    let initialStateFactory: @Sendable (LandID) -> CounterTestState = { _ in
        CounterTestState()
    }

    let manager = LandManager<CounterTestState>(
        landFactory: landFactory,
        initialStateFactory: initialStateFactory
    )

    let landID = LandID("counter-test")
    let playerID1 = PlayerID("player-1")
    let clientID1 = ClientID("client-1")
    let sessionID1 = SessionID("session-1")

    // Act - Create land and join player
    let definition = landFactory(landID)
    let initialState = initialStateFactory(landID)
    let container1 = await manager.getOrCreateLand(landID: landID, definition: definition, initialState: initialState)

    // Join player and modify state using action
    _ = try await container1.keeper.join(playerID: playerID1, clientID: clientID1, sessionID: sessionID1)

    // Modify state by executing action (increment to 7)
    let action = IncrementTestAction(amount: 7)
    _ = try await container1.keeper.handleAction(action, playerID: playerID1, clientID: clientID1, sessionID: sessionID1)

    // Verify state was modified
    let stateAfterModification = await container1.keeper.currentState()
    #expect(stateAfterModification.count == 7, "State should be modified to 7")

    // Leave player to trigger destroy
    try await container1.keeper.leave(playerID: playerID1, clientID: clientID1)

    // Wait for destroy to complete and auto-removal
    try await Task.sleep(for: .milliseconds(150))

    // Verify land has been automatically removed
    let landAfterDestroy = await manager.getLand(landID: landID)
    #expect(landAfterDestroy == nil, "Land should be automatically removed after destroy")

    // Recreate land with same landID
    let newInitialState = initialStateFactory(landID)
    let container2 = await manager.getOrCreateLand(landID: landID, definition: definition, initialState: newInitialState)

    // Assert - New land should have fresh initial state (count = 0), not old state (count = 7)
    let stateAfterRecreate = await container2.keeper.currentState()
    #expect(stateAfterRecreate.count == 0, "Recreated land should have fresh initial state (count = 0), not old state (count = 7)")
    #expect(container1.landID == container2.landID, "Should have same landID")

    // Verify it's actually a new container (different keeper instance)
    let playerCountAfterRecreate = await container2.keeper.playerCount()
    #expect(playerCountAfterRecreate == 0, "New land should start with no players")
}
