// Examples/GameDemo/Tests/MonsterSystemTests.swift
//
// Unit tests for MonsterSystem logic.
// These tests ensure monster spawning and AI behavior are correct.

import Foundation
import Testing
import Logging
@testable import GameContent
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// Helper to create a test context with default config, RNG, and optional tickId
func createMonsterTestContext(tickId: Int64? = nil, seed: UInt64 = 12345) -> LandContext {
    let configProvider = DefaultGameConfigProvider()
    var services = LandServices()
    services.register(GameConfigProviderService(provider: configProvider), as: GameConfigProviderService.self)
    services.register(DeterministicRngService(seed: seed), as: DeterministicRngService.self)
    
    return LandContext(
        landID: "test",
        playerID: LandContext.systemPlayerID,
        clientID: LandContext.systemClientID,
        sessionID: LandContext.systemSessionID,
        services: services,
        logger: Logger(label: "test"),
        tickId: tickId,
        sendEventHandler: { _, _ in },
        syncHandler: { }
    )
}

// MARK: - Spawn Interval Tests

@Test("MonsterSystem.getMonsterSpawnInterval returns max interval at start")
func testGetMonsterSpawnIntervalAtStart() {
    let ctx = createMonsterTestContext(tickId: 0)
    let interval = MonsterSystem.getMonsterSpawnInterval(ctx)
    #expect(interval == 30)  // Max interval from GameConfig
}

@Test("MonsterSystem.getMonsterSpawnInterval decreases over time")
func testGetMonsterSpawnIntervalDecreases() {
    let ctx0 = createMonsterTestContext(tickId: 0)
    let interval0 = MonsterSystem.getMonsterSpawnInterval(ctx0)
    
    let ctx1500 = createMonsterTestContext(tickId: 1500)  // Halfway to acceleration
    let interval1500 = MonsterSystem.getMonsterSpawnInterval(ctx1500)
    
    #expect(interval1500 < interval0)
}

@Test("MonsterSystem.getMonsterSpawnInterval reaches min interval at acceleration point")
func testGetMonsterSpawnIntervalReachesMin() {
    let ctx = createMonsterTestContext(tickId: 3000)  // At acceleration point
    let interval = MonsterSystem.getMonsterSpawnInterval(ctx)
    #expect(interval == 3)  // Min interval from GameConfig
}

@Test("MonsterSystem.getMonsterSpawnInterval returns fallback when tickId is nil")
func testGetMonsterSpawnIntervalFallback() {
    let ctx = createMonsterTestContext(tickId: nil)
    let interval = MonsterSystem.getMonsterSpawnInterval(ctx)
    #expect(interval == 100)  // Default fallback
}

// MARK: - Monster Spawning Tests

@Test("MonsterSystem.spawnMonster creates monster with correct properties")
func testSpawnMonsterCreatesMonster() {
    let ctx = createMonsterTestContext()
    let monster = MonsterSystem.spawnMonster(nextID: 1, ctx)
    
    #expect(monster.id == 1)
    #expect(monster.health == 10)  // Base health from GameConfig
    #expect(monster.maxHealth == 10)
    #expect(monster.reward == 10)  // Base reward from GameConfig
    #expect(monster.pathProgress == 0.0)
}

@Test("MonsterSystem.spawnMonster spawns at edge position")
func testSpawnMonsterAtEdge() {
    let ctx = createMonsterTestContext()
    let monster = MonsterSystem.spawnMonster(nextID: 1, ctx)
    
    // Monster should be spawned at one of the edges
    let posX = Float(monster.spawnPosition.v.x) / 1000.0
    let posY = Float(monster.spawnPosition.v.y) / 1000.0
    
    // Check if on any edge (within small tolerance)
    let onTopEdge = abs(posY) < 0.1
    let onBottomEdge = abs(posY - 72.0) < 0.1
    let onLeftEdge = abs(posX) < 0.1
    let onRightEdge = abs(posX - 128.0) < 0.1
    
    #expect(onTopEdge || onBottomEdge || onLeftEdge || onRightEdge)
}

@Test("MonsterSystem.spawnMonster sets position to spawn position")
func testSpawnMonsterSetsPosition() {
    let ctx = createMonsterTestContext()
    let monster = MonsterSystem.spawnMonster(nextID: 1, ctx)
    
    #expect(monster.position == monster.spawnPosition)
}

@Test("MonsterSystem.spawnMonster is deterministic with same seed")
func testSpawnMonsterDeterministic() {
    let seed: UInt64 = 12345
    let ctx1 = createMonsterTestContext(seed: seed)
    let ctx2 = createMonsterTestContext(seed: seed)
    
    let monster1 = MonsterSystem.spawnMonster(nextID: 1, ctx1)
    let monster2 = MonsterSystem.spawnMonster(nextID: 1, ctx2)
    
    #expect(monster1.spawnPosition == monster2.spawnPosition)
}

// MARK: - Base Interaction Tests

@Test("MonsterSystem.checkMonsterReachedBase returns true when monster is within base radius")
func testCheckMonsterReachedBaseWithinRadius() {
    var base = BaseState()
    base.position = Position2(x: 64.0, y: 36.0)
    base.health = 100
    
    var monster = MonsterState()
    monster.position = Position2(x: 64.0, y: 36.0 + 2.0)  // Within 3.0 radius
    
    let ctx = createMonsterTestContext()
    let reached = MonsterSystem.checkMonsterReachedBase(monster, base: &base, ctx)
    
    #expect(reached == true)
    #expect(base.health == 99)  // Should take 1 damage
}

@Test("MonsterSystem.checkMonsterReachedBase returns false when monster is outside radius")
func testCheckMonsterReachedBaseOutsideRadius() {
    var base = BaseState()
    base.position = Position2(x: 64.0, y: 36.0)
    base.health = 100
    
    var monster = MonsterState()
    monster.position = Position2(x: 64.0, y: 36.0 + 5.0)  // Outside 3.0 radius
    
    let ctx = createMonsterTestContext()
    let reached = MonsterSystem.checkMonsterReachedBase(monster, base: &base, ctx)
    
    #expect(reached == false)
    #expect(base.health == 100)  // Should not take damage
}

@Test("MonsterSystem.checkMonsterReachedBase prevents negative health")
func testCheckMonsterReachedBasePreventsNegativeHealth() {
    var base = BaseState()
    base.position = Position2(x: 64.0, y: 36.0)
    base.health = 0  // Already at 0
    
    var monster = MonsterState()
    monster.position = Position2(x: 64.0, y: 36.0 + 2.0)
    
    let ctx = createMonsterTestContext()
    _ = MonsterSystem.checkMonsterReachedBase(monster, base: &base, ctx)
    
    #expect(base.health == 0)  // Should not go negative
}
