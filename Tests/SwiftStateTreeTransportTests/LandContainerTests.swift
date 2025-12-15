// Tests/SwiftStateTreeTransportTests/LandContainerTests.swift
//
// Tests for LandContainer - single room container functionality

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct ContainerTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var ticks: Int = 0
}

// MARK: - Tests

@Test("LandContainer can get current state")
func testLandContainerGetCurrentState() async throws {
    // Arrange
    let landID = LandID("test-land")
    let definition = Land(landID.stringValue, using: ContainerTestState.self) {
        Rules {}
    }
    var initialState = ContainerTestState()
    initialState.ticks = 42
    
    let keeper = LandKeeper<ContainerTestState>(definition: definition, initialState: initialState)
    let transport = WebSocketTransport()
    let adapter = TransportAdapter<ContainerTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    
    let container = LandContainer<ContainerTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: adapter
    )
    
    // Act
    let state = await container.currentState()
    
    // Assert
    #expect(state.ticks == 42)
}

@Test("LandContainer provides statistics")
func testLandContainerGetStats() async throws {
    // Arrange
    let landID = LandID("test-land")
    let definition = Land(landID.stringValue, using: ContainerTestState.self) {
        Rules {}
    }
    let initialState = ContainerTestState()
    
    let keeper = LandKeeper<ContainerTestState>(definition: definition, initialState: initialState)
    let transport = WebSocketTransport()
    let adapter = TransportAdapter<ContainerTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    
    let container = LandContainer<ContainerTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: adapter
    )
    
    let createdAt = Date()
    
    // Act
    let stats = await container.getStats(createdAt: createdAt)
    
    // Assert
    #expect(stats.landID == landID)
    #expect(stats.playerCount == 0)
    #expect(stats.createdAt == createdAt)
}

