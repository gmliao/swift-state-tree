// Examples/GameDemo/Tests/TurretSystemTests.swift
//
// Unit tests for TurretSystem logic.
// These tests ensure turret placement validation is correct.

import Foundation
import Testing
import Logging
@testable import GameContent
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// Helper to create a test context with default config
func createTurretTestContext() -> LandContext {
    let configProvider = DefaultGameConfigProvider()
    var services = LandServices()
    services.register(GameConfigProviderService(provider: configProvider), as: GameConfigProviderService.self)
    
    return LandContext(
        landID: "test",
        playerID: LandContext.systemPlayerID,
        clientID: LandContext.systemClientID,
        sessionID: LandContext.systemSessionID,
        services: services,
        logger: Logger(label: "test"),
        tickId: nil,
        sendEventHandler: { _, _ in },
        syncHandler: { }
    )
}

// MARK: - Turret Placement Validation Tests

@Test("TurretSystem.isValidTurretPosition returns true for valid position")
func testIsValidTurretPositionValid() {
    let basePosition = Position2(x: 64.0, y: 36.0)
    let position = Position2(x: 72.0, y: 36.0)  // 8 units from base (minimum distance)
    let existingTurrets: [Int: TurretState] = [:]
    
    let ctx = createTurretTestContext()
    let isValid = TurretSystem.isValidTurretPosition(position, basePosition: basePosition, existingTurrets: existingTurrets, ctx)
    
    #expect(isValid == true)
}

@Test("TurretSystem.isValidTurretPosition returns false when too close to base")
func testIsValidTurretPositionTooCloseToBase() {
    let basePosition = Position2(x: 64.0, y: 36.0)
    let position = Position2(x: 66.0, y: 36.0)  // Only 2 units from base (too close)
    let existingTurrets: [Int: TurretState] = [:]
    
    let ctx = createTurretTestContext()
    let isValid = TurretSystem.isValidTurretPosition(position, basePosition: basePosition, existingTurrets: existingTurrets, ctx)
    
    #expect(isValid == false)
}

@Test("TurretSystem.isValidTurretPosition returns false when too close to existing turret")
func testIsValidTurretPositionTooCloseToTurret() {
    let basePosition = Position2(x: 64.0, y: 36.0)
    let position = Position2(x: 72.0, y: 36.0)
    
    var existingTurrets: [Int: TurretState] = [:]
    var turret = TurretState()
    turret.position = Position2(x: 73.0, y: 36.0)  // Only 1 unit away (too close, min is 3)
    existingTurrets[1] = turret
    
    let ctx = createTurretTestContext()
    let isValid = TurretSystem.isValidTurretPosition(position, basePosition: basePosition, existingTurrets: existingTurrets, ctx)
    
    #expect(isValid == false)
}

@Test("TurretSystem.isValidTurretPosition returns true when far enough from existing turret")
func testIsValidTurretPositionFarEnoughFromTurret() {
    let basePosition = Position2(x: 64.0, y: 36.0)
    let position = Position2(x: 72.0, y: 36.0)
    
    var existingTurrets: [Int: TurretState] = [:]
    var turret = TurretState()
    turret.position = Position2(x: 76.0, y: 36.0)  // 4 units away (enough, min is 3)
    existingTurrets[1] = turret
    
    let ctx = createTurretTestContext()
    let isValid = TurretSystem.isValidTurretPosition(position, basePosition: basePosition, existingTurrets: existingTurrets, ctx)
    
    #expect(isValid == true)
}

@Test("TurretSystem.isValidTurretPosition returns false when outside world bounds")
func testIsValidTurretPositionOutsideBounds() {
    let basePosition = Position2(x: 64.0, y: 36.0)
    let position = Position2(x: 200.0, y: 36.0)  // Outside world width (128)
    let existingTurrets: [Int: TurretState] = [:]
    
    let ctx = createTurretTestContext()
    let isValid = TurretSystem.isValidTurretPosition(position, basePosition: basePosition, existingTurrets: existingTurrets, ctx)
    
    #expect(isValid == false)
}

@Test("TurretSystem.isValidTurretPosition returns false for negative coordinates")
func testIsValidTurretPositionNegativeCoordinates() {
    let basePosition = Position2(x: 64.0, y: 36.0)
    let position = Position2(x: -10.0, y: 36.0)  // Negative X
    let existingTurrets: [Int: TurretState] = [:]
    
    let ctx = createTurretTestContext()
    let isValid = TurretSystem.isValidTurretPosition(position, basePosition: basePosition, existingTurrets: existingTurrets, ctx)
    
    #expect(isValid == false)
}

@Test("TurretSystem.isValidTurretPosition handles multiple existing turrets")
func testIsValidTurretPositionMultipleTurrets() {
    let basePosition = Position2(x: 64.0, y: 36.0)
    let position = Position2(x: 80.0, y: 40.0)
    
    var existingTurrets: [Int: TurretState] = [:]
    var turret1 = TurretState()
    turret1.position = Position2(x: 76.0, y: 36.0)  // Far enough
    existingTurrets[1] = turret1
    
    var turret2 = TurretState()
    turret2.position = Position2(x: 82.0, y: 40.0)  // Too close (2 units)
    existingTurrets[2] = turret2
    
    let ctx = createTurretTestContext()
    let isValid = TurretSystem.isValidTurretPosition(position, basePosition: basePosition, existingTurrets: existingTurrets, ctx)
    
    #expect(isValid == false)  // Should fail because turret2 is too close
}
