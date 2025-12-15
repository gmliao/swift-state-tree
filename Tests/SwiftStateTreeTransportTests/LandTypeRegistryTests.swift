// Tests/SwiftStateTreeTransportTests/LandTypeRegistryTests.swift
//
// Tests for LandTypeRegistry - land type configuration management

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

#if canImport(Foundation)
import Foundation
#endif

// MARK: - Test State

@StateNodeBuilder
struct LandTypeRegistryTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Test("LandTypeRegistry can create LandDefinition for different land types")
func testLandTypeRegistryCreatesLandDefinition() async throws {
    // Arrange
    let registry = LandTypeRegistry<LandTypeRegistryTestState>(
        landFactory: { landType, landID in
            Land(landType, using: LandTypeRegistryTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { _, _ in
            LandTypeRegistryTestState()
        }
    )
    
    // Act
    let landID1 = LandID("land-1")
    let definition1 = registry.getLandDefinition(landType: "battle-royale", landID: landID1)
    
    let landID2 = LandID("land-2")
    let definition2 = registry.getLandDefinition(landType: "1v1", landID: landID2)
    
    // Assert
    #expect(definition1.id == "battle-royale")
    #expect(definition2.id == "1v1")
}

@Test("LandTypeRegistry validates LandDefinition.id matches landType")
func testLandTypeRegistryValidatesLandDefinitionID() async throws {
    // Arrange - Create a registry that correctly matches IDs
    let registry = LandTypeRegistry<LandTypeRegistryTestState>(
        landFactory: { landType, landID in
            // Correctly return ID matching landType
            Land(landType, using: LandTypeRegistryTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { _, _ in
            LandTypeRegistryTestState()
        }
    )
    
    // Act & Assert
    let landID = LandID("test-land")
    let definition = registry.getLandDefinition(landType: "test-type", landID: landID)
    
    // Verify that the definition ID matches the landType
    // This tests that the validation logic works correctly when IDs match
    #expect(definition.id == "test-type")
    
    // Note: Testing assertion failure for mismatched IDs is difficult in Swift Testing
    // The assertion in getLandDefinition will catch mismatches in debug builds
    // This test verifies the happy path where IDs match correctly
}

@Test("LandTypeRegistry creates initial state for different land types")
func testLandTypeRegistryCreatesInitialState() async throws {
    // Arrange
    final class StateTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var _createdStates: [String] = []
        
        var createdStates: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _createdStates
        }
        
        func append(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            _createdStates.append(value)
        }
    }
    
    let tracker = StateTracker()
    
    let registry = LandTypeRegistry<LandTypeRegistryTestState>(
        landFactory: { landType, landID in
            Land(landType, using: LandTypeRegistryTestState.self) {
                Rules {}
            }
        },
        initialStateFactory: { landType, landID in
            tracker.append("\(landType)-\(landID.stringValue)")
            return LandTypeRegistryTestState()
        }
    )
    
    // Act
    let landID1 = LandID("land-1")
    let state1 = registry.initialStateFactory("battle-royale", landID1)
    
    let landID2 = LandID("land-2")
    let state2 = registry.initialStateFactory("1v1", landID2)
    
    // Assert
    #expect(state1.players.isEmpty)
    #expect(state2.players.isEmpty)
    #expect(tracker.createdStates.contains("battle-royale-land-1"))
    #expect(tracker.createdStates.contains("1v1-land-2"))
}

