// Examples/GameDemo/Tests/CombatSystemTests.swift
//
// Unit tests for CombatSystem logic.
// These tests ensure combat calculations (damage, range, targeting) are correct.

import Foundation
import Testing
import Logging
@testable import GameContent
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// Helper to create a test context with default config and optional tickId
func createCombatTestContext(tickId: Int64? = nil) -> LandContext {
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
        tickId: tickId,
        sendEventHandler: { _, _ in },
        syncHandler: { }
    )
}

// MARK: - Weapon Damage and Range Tests

@Test("CombatSystem.getWeaponDamage calculates base damage correctly")
func testGetWeaponDamageBase() {
    let ctx = createCombatTestContext()
    let damage = CombatSystem.getWeaponDamage(level: 0, ctx)
    #expect(damage == 5)  // Base damage from GameConfig
}

@Test("CombatSystem.getWeaponDamage increases with level")
func testGetWeaponDamageIncreasesWithLevel() {
    let ctx = createCombatTestContext()
    let damage0 = CombatSystem.getWeaponDamage(level: 0, ctx)
    let damage1 = CombatSystem.getWeaponDamage(level: 1, ctx)
    let damage2 = CombatSystem.getWeaponDamage(level: 2, ctx)
    
    #expect(damage1 == damage0 + 2)
    #expect(damage2 == damage0 + 4)
}

@Test("CombatSystem.getWeaponRange calculates base range correctly")
func testGetWeaponRangeBase() {
    let ctx = createCombatTestContext()
    let range = CombatSystem.getWeaponRange(level: 0, ctx)
    #expect(range == 20.0)  // Base range from GameConfig
}

@Test("CombatSystem.getWeaponRange increases with level")
func testGetWeaponRangeIncreasesWithLevel() {
    let ctx = createCombatTestContext()
    let range0 = CombatSystem.getWeaponRange(level: 0, ctx)
    let range1 = CombatSystem.getWeaponRange(level: 1, ctx)
    let range2 = CombatSystem.getWeaponRange(level: 2, ctx)
    
    #expect(range1 == range0 + 2.0)
    #expect(range2 == range0 + 4.0)
}

// MARK: - Fire Rate Tests

@Test("CombatSystem.canPlayerFire returns true when enough time has passed")
func testCanPlayerFireWhenReady() {
    var player = PlayerState()
    player.lastFireTick = 0
    
    let ctx = createCombatTestContext(tickId: 10)  // Fire rate is 10 ticks
    let canFire = CombatSystem.canPlayerFire(player, ctx)
    #expect(canFire == true)
}

@Test("CombatSystem.canPlayerFire returns false when on cooldown")
func testCanPlayerFireOnCooldown() {
    var player = PlayerState()
    player.lastFireTick = 5
    
    let ctx = createCombatTestContext(tickId: 10)  // Only 5 ticks passed, need 10
    let canFire = CombatSystem.canPlayerFire(player, ctx)
    #expect(canFire == false)
}

@Test("CombatSystem.canPlayerFire returns false when tickId is nil")
func testCanPlayerFireWithoutTickId() {
    let player = PlayerState()
    let ctx = createCombatTestContext(tickId: nil)
    let canFire = CombatSystem.canPlayerFire(player, ctx)
    #expect(canFire == false)
}

// MARK: - Targeting Tests

@Test("CombatSystem.findNearestMonsterInRange finds nearest monster")
func testFindNearestMonsterInRange() {
    let position = Position2(x: 0.0, y: 0.0)
    let range: Float = 20.0
    
    var monsters: [Int: MonsterState] = [:]
    var monster1 = MonsterState()
    monster1.position = Position2(x: 5.0, y: 0.0)  // Close
    monsters[1] = monster1
    
    var monster2 = MonsterState()
    monster2.position = Position2(x: 15.0, y: 0.0)  // Further but in range
    monsters[2] = monster2
    
    var monster3 = MonsterState()
    monster3.position = Position2(x: 25.0, y: 0.0)  // Out of range
    monsters[3] = monster3
    
    let result = CombatSystem.findNearestMonsterInRange(from: position, range: range, monsters: monsters)
    
    #expect(result != nil)
    #expect(result?.id == 1)  // Should find nearest (monster1)
}

@Test("CombatSystem.findNearestMonsterInRange returns nil when no monsters in range")
func testFindNearestMonsterInRangeNoTargets() {
    let position = Position2(x: 0.0, y: 0.0)
    let range: Float = 10.0
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.position = Position2(x: 20.0, y: 0.0)  // Out of range
    monsters[1] = monster
    
    let result = CombatSystem.findNearestMonsterInRange(from: position, range: range, monsters: monsters)
    #expect(result == nil)
}

// MARK: - Player Shooting Tests

@Test("CombatSystem.processPlayerShoot fires at nearest monster")
func testProcessPlayerShootFiresAtNearest() {
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.weaponLevel = 0
    player.lastFireTick = 0
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.id = 1
    monster.position = Position2(x: 10.0, y: 0.0)  // In range
    monster.health = 10
    monsters[1] = monster
    
    let ctx = createCombatTestContext(tickId: 10)
    let result = CombatSystem.processPlayerShoot(player: &player, monsters: &monsters, ctx)
    
    #expect(result != nil)
    #expect(result?.targetID == 1)
    #expect(player.lastFireTick == 10)
}

@Test("CombatSystem.processPlayerShoot applies damage")
func testProcessPlayerShootAppliesDamage() {
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.weaponLevel = 0
    player.lastFireTick = 0
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.id = 1
    monster.position = Position2(x: 10.0, y: 0.0)
    monster.health = 10
    monsters[1] = monster
    
    let ctx = createCombatTestContext(tickId: 10)
    let result = CombatSystem.processPlayerShoot(player: &player, monsters: &monsters, ctx)
    
    #expect(result != nil)
    #expect(result?.defeated == false)  // Monster has 10 health, damage is 5
    #expect(monsters[1]?.health == 5)  // Should have taken 5 damage
}

@Test("CombatSystem.processPlayerShoot defeats monster and awards resources")
func testProcessPlayerShootDefeatsMonster() {
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.weaponLevel = 0
    player.lastFireTick = 0
    player.resources = 0
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.id = 1
    monster.position = Position2(x: 10.0, y: 0.0)
    monster.health = 5  // Will be defeated by 5 damage
    monster.reward = 10
    monsters[1] = monster
    
    let ctx = createCombatTestContext(tickId: 10)
    let result = CombatSystem.processPlayerShoot(player: &player, monsters: &monsters, ctx)
    
    #expect(result != nil)
    #expect(result?.defeated == true)
    #expect(result?.rewardGained == 10)
    #expect(player.resources == 10)
    #expect(monsters[1] == nil)  // Monster should be removed
}

@Test("CombatSystem.processPlayerShoot returns nil when no target in range")
func testProcessPlayerShootNoTarget() {
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.weaponLevel = 0
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.position = Position2(x: 30.0, y: 0.0)  // Out of range (range is 20)
    monsters[1] = monster
    
    let ctx = createCombatTestContext(tickId: 10)
    let result = CombatSystem.processPlayerShoot(player: &player, monsters: &monsters, ctx)
    
    #expect(result == nil)
}

@Test("CombatSystem.processPlayerShoot auto-aims player towards target")
func testProcessPlayerShootAutoAims() {
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.weaponLevel = 0
    player.lastFireTick = 0
    player.rotation = Angle(degrees: 0.0)
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.position = Position2(x: 10.0, y: 10.0)  // 45 degree angle
    monsters[1] = monster
    
    let ctx = createCombatTestContext(tickId: 10)
    _ = CombatSystem.processPlayerShoot(player: &player, monsters: &monsters, ctx)
    
    // Player should be rotated towards monster (approximately 45 degrees)
    let expectedAngle = Angle(degrees: 45.0)
    let angleDiff = abs(player.rotation.floatDegrees - expectedAngle.floatDegrees)
    #expect(angleDiff < 5.0)  // Allow 5 degree tolerance
}

// MARK: - Turret Damage and Range Tests

@Test("CombatSystem.getTurretDamage calculates base damage correctly")
func testGetTurretDamageBase() {
    let ctx = createCombatTestContext()
    let damage = CombatSystem.getTurretDamage(level: 0, ctx)
    #expect(damage == 3)  // Base damage from GameConfig
}

@Test("CombatSystem.getTurretDamage increases with level")
func testGetTurretDamageIncreasesWithLevel() {
    let ctx = createCombatTestContext()
    let damage0 = CombatSystem.getTurretDamage(level: 0, ctx)
    let damage1 = CombatSystem.getTurretDamage(level: 1, ctx)
    
    #expect(damage1 == damage0 + 1)
}

@Test("CombatSystem.getTurretRange calculates base range correctly")
func testGetTurretRangeBase() {
    let ctx = createCombatTestContext()
    let range = CombatSystem.getTurretRange(level: 0, ctx)
    #expect(range == 15.0)  // Base range from GameConfig
}

@Test("CombatSystem.getTurretRange increases with level")
func testGetTurretRangeIncreasesWithLevel() {
    let ctx = createCombatTestContext()
    let range0 = CombatSystem.getTurretRange(level: 0, ctx)
    let range1 = CombatSystem.getTurretRange(level: 1, ctx)
    
    #expect(range1 == range0 + 1.0)
}

@Test("CombatSystem.canTurretFire returns true when ready")
func testCanTurretFireWhenReady() {
    var turret = TurretState()
    turret.lastFireTick = 0
    
    let ctx = createCombatTestContext(tickId: 20)  // Fire rate is 20 ticks
    let canFire = CombatSystem.canTurretFire(turret, ctx)
    #expect(canFire == true)
}

@Test("CombatSystem.canTurretFire returns false when on cooldown")
func testCanTurretFireOnCooldown() {
    var turret = TurretState()
    turret.lastFireTick = 10
    
    let ctx = createCombatTestContext(tickId: 20)  // Only 10 ticks passed, need 20
    let canFire = CombatSystem.canTurretFire(turret, ctx)
    #expect(canFire == false)
}

// MARK: - Turret Shooting Tests

@Test("CombatSystem.processTurretShoot fires at nearest monster")
func testProcessTurretShootFiresAtNearest() {
    var turret = TurretState()
    turret.position = Position2(x: 0.0, y: 0.0)
    turret.level = 0
    turret.lastFireTick = 0
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.id = 1
    monster.position = Position2(x: 10.0, y: 0.0)  // In range
    monster.health = 10
    monsters[1] = monster
    
    let ctx = createCombatTestContext(tickId: 20)
    let result = CombatSystem.processTurretShoot(turret: &turret, monsters: &monsters, ctx)
    
    #expect(result != nil)
    #expect(result?.targetID == 1)
    #expect(turret.lastFireTick == 20)
}

@Test("CombatSystem.processTurretShoot applies damage")
func testProcessTurretShootAppliesDamage() {
    var turret = TurretState()
    turret.position = Position2(x: 0.0, y: 0.0)
    turret.level = 0
    turret.lastFireTick = 0
    
    var monsters: [Int: MonsterState] = [:]
    var monster = MonsterState()
    monster.id = 1
    monster.position = Position2(x: 10.0, y: 0.0)
    monster.health = 10
    monsters[1] = monster
    
    let ctx = createCombatTestContext(tickId: 20)
    let result = CombatSystem.processTurretShoot(turret: &turret, monsters: &monsters, ctx)
    
    #expect(result != nil)
    #expect(result?.defeated == false)  // Monster has 10 health, damage is 3
    #expect(monsters[1]?.health == 7)  // Should have taken 3 damage
}

// MARK: - Damage Helper Tests

@Test("CombatSystem.damageMonster reduces health")
func testDamageMonster() {
    var monster = MonsterState()
    monster.health = 10
    
    let defeated = CombatSystem.damageMonster(&monster, damage: 5)
    
    #expect(monster.health == 5)
    #expect(defeated == false)
}

@Test("CombatSystem.damageMonster defeats monster when health reaches zero")
func testDamageMonsterDefeats() {
    var monster = MonsterState()
    monster.health = 5
    
    let defeated = CombatSystem.damageMonster(&monster, damage: 5)
    
    #expect(monster.health == 0)
    #expect(defeated == true)
}

@Test("CombatSystem.damageMonster prevents negative health")
func testDamageMonsterPreventsNegativeHealth() {
    var monster = MonsterState()
    monster.health = 3
    
    let defeated = CombatSystem.damageMonster(&monster, damage: 10)
    
    #expect(monster.health == 0)
    #expect(defeated == true)
}
