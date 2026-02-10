import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Combat System

/// System functions for combat logic (damage, targeting, etc.)
public enum CombatSystem {
    // MARK: - Player Combat
    
    /// Calculate weapon damage based on level
    public static func getWeaponDamage(level: Int, _ ctx: LandContext) -> Int {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return 0
        }
        let config = configService.provider
        return config.weaponBaseDamage + (level * 2)
    }
    
    /// Calculate weapon range based on level
    public static func getWeaponRange(level: Int, _ ctx: LandContext) -> Float {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return 0.0
        }
        let config = configService.provider
        return config.weaponBaseRange + (Float(level) * 2.0)
    }
    
    /// Check if player can fire (fire rate check)
    public static func canPlayerFire(_ player: PlayerState, _ ctx: LandContext) -> Bool {
        guard let tickId = ctx.tickId,
              let configService = ctx.services.get(GameConfigProviderService.self) else {
            return false
        }
        let config = configService.provider
        let fireRate = Int64(config.weaponFireRateTicks)
        return tickId - player.lastFireTick >= fireRate
    }
    
    /// Find nearest monster within range
    public static func findNearestMonsterInRange(
        from position: Position2,
        range: Float,
        monsters: ReactiveDictionary<Int, MonsterState>
    ) -> (id: Int, monster: MonsterState)? {
        var nearest: (id: Int, monster: MonsterState)? = nil
        var nearestDistance: Float = Float.greatestFiniteMagnitude
        
        for (id, monster) in monsters.toDictionary() {
            let distance = position.v.distance(to: monster.position.v)
            if distance <= range && distance < nearestDistance {
                nearest = (id, monster)
                nearestDistance = distance
            }
        }
        
        return nearest
    }
    
    /// Result of player shooting at a monster
    public struct ShootResult: Sendable {
        public let shooterPosition: Position2
        public let targetPosition: Position2
        public let targetID: Int
        public let defeated: Bool
        public let rewardGained: Int
        
        public init(shooterPosition: Position2, targetPosition: Position2, targetID: Int, defeated: Bool, rewardGained: Int) {
            self.shooterPosition = shooterPosition
            self.targetPosition = targetPosition
            self.targetID = targetID
            self.defeated = defeated
            self.rewardGained = rewardGained
        }
    }
    
    /// Process player shooting at nearest monster in range.
    /// Returns ShootResult if a shot was fired, nil otherwise.
    ///
    /// This function:
    /// - Finds nearest monster in range
    /// - Auto-aims player towards monster
    /// - Applies damage
    /// - Awards resources if monster is defeated
    /// - Returns information needed for broadcasting shoot event
    ///
    /// - Parameters:
    ///   - player: Player state (will be mutated: rotation, resources, lastFireTick)
    ///   - monsters: Dictionary of monsters (will be mutated if monster is defeated)
    /// - Returns: ShootResult if shot was fired, nil if no target in range
    public static func processPlayerShoot(
        player: inout PlayerState,
        monsters: inout ReactiveDictionary<Int, MonsterState>,
        _ ctx: LandContext
    ) -> ShootResult? {
        guard let tickId = ctx.tickId else {
            return nil
        }
        
        // Find nearest monster in range
        let range = getWeaponRange(level: player.weaponLevel, ctx)
        guard let (monsterID, monster) = findNearestMonsterInRange(
            from: player.position,
            range: range,
            monsters: monsters
        ) else {
            return nil
        }
        
        // Auto-aim: Rotate player towards monster
        let direction = monster.position.v - player.position.v
        let angleRad = direction.toAngle()
        player.rotation = Angle(radians: angleRad)
        
        // Save positions for event (before mutation)
        let playerPos = player.position
        let monsterPos = monster.position
        
        // Apply damage
        var updatedMonster = monster
        let damage = getWeaponDamage(level: player.weaponLevel, ctx)
        let defeated = damageMonster(&updatedMonster, damage: damage)
        
        var rewardGained = 0
        if defeated {
            // Monster defeated, give resources
            rewardGained = updatedMonster.reward
            player.resources += rewardGained
            monsters.removeValue(forKey: monsterID)
        } else {
            monsters[monsterID] = updatedMonster
        }
        
        // Update fire tick
        player.lastFireTick = tickId
        
        return ShootResult(
            shooterPosition: playerPos,
            targetPosition: monsterPos,
            targetID: monsterID,
            defeated: defeated,
            rewardGained: rewardGained
        )
    }
    
    // MARK: - Turret Combat
    
    /// Calculate turret damage based on level
    public static func getTurretDamage(level: Int, _ ctx: LandContext) -> Int {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return 0
        }
        let config = configService.provider
        return config.turretBaseDamage + (level * 1)
    }
    
    /// Calculate turret range based on level
    public static func getTurretRange(level: Int, _ ctx: LandContext) -> Float {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return 0.0
        }
        let config = configService.provider
        return config.turretBaseRange + (Float(level) * 1.0)
    }
    
    /// Check if turret can fire (fire rate check)
    public static func canTurretFire(_ turret: TurretState, _ ctx: LandContext) -> Bool {
        guard let tickId = ctx.tickId,
              let configService = ctx.services.get(GameConfigProviderService.self) else {
            return false
        }
        let config = configService.provider
        let fireRate = Int64(config.turretFireRateTicks)
        return tickId - turret.lastFireTick >= fireRate
    }
    
    /// Find nearest monster within turret range
    public static func findNearestMonsterInTurretRange(
        from position: Position2,
        range: Float,
        monsters: ReactiveDictionary<Int, MonsterState>
    ) -> (id: Int, monster: MonsterState)? {
        return findNearestMonsterInRange(from: position, range: range, monsters: monsters)
    }
    
    /// Result of turret shooting at a monster
    public struct TurretShootResult: Sendable {
        public let turretPosition: Position2
        public let targetPosition: Position2
        public let targetID: Int
        public let defeated: Bool
        public let rewardGained: Int
        
        public init(turretPosition: Position2, targetPosition: Position2, targetID: Int, defeated: Bool, rewardGained: Int) {
            self.turretPosition = turretPosition
            self.targetPosition = targetPosition
            self.targetID = targetID
            self.defeated = defeated
            self.rewardGained = rewardGained
        }
    }
    
    /// Process turret shooting at nearest monster in range.
    /// Returns TurretShootResult if a shot was fired, nil otherwise.
    ///
    /// This function:
    /// - Finds nearest monster in range
    /// - Rotates turret towards monster
    /// - Applies damage
    /// - Returns information needed for broadcasting shoot event and awarding resources
    ///
    /// - Parameters:
    ///   - turret: Turret state (will be mutated: rotation, lastFireTick)
    ///   - monsters: Dictionary of monsters (will be mutated if monster is defeated)
    /// - Returns: TurretShootResult if shot was fired, nil if no target in range
    public static func processTurretShoot(
        turret: inout TurretState,
        monsters: inout ReactiveDictionary<Int, MonsterState>,
        _ ctx: LandContext
    ) -> TurretShootResult? {
        guard let tickId = ctx.tickId else {
            return nil
        }
        
        // Find nearest monster in range
        let range = getTurretRange(level: turret.level, ctx)
        guard let (monsterID, monster) = findNearestMonsterInTurretRange(
            from: turret.position,
            range: range,
            monsters: monsters
        ) else {
            return nil
        }
        
        // Rotate turret towards target
        let direction = monster.position.v - turret.position.v
        let angleRad = direction.toAngle()
        turret.rotation = Angle(radians: angleRad)
        
        // Save positions for event (before mutation)
        let turretPos = turret.position
        let monsterPos = monster.position
        
        // Apply damage
        var updatedMonster = monster
        let damage = getTurretDamage(level: turret.level, ctx)
        let defeated = damageMonster(&updatedMonster, damage: damage)
        
        var rewardGained = 0
        if defeated {
            // Monster defeated
            rewardGained = updatedMonster.reward
            monsters.removeValue(forKey: monsterID)
        } else {
            monsters[monsterID] = updatedMonster
        }
        
        // Update fire tick
        turret.lastFireTick = tickId
        
        return TurretShootResult(
            turretPosition: turretPos,
            targetPosition: monsterPos,
            targetID: monsterID,
            defeated: defeated,
            rewardGained: rewardGained
        )
    }
    
    // MARK: - Damage
    
    /// Apply damage to monster (returns true if monster is defeated)
    public static func damageMonster(_ monster: inout MonsterState, damage: Int) -> Bool {
        monster.health = max(0, monster.health - damage)
        return monster.health <= 0
    }
    
    /// Calculate distance from a point to a line segment
    public static func distanceToLineSegment(
        point: Position2,
        lineStart: Position2,
        lineEnd: Position2
    ) -> Float {
        let pointVec = point.v
        let startVec = lineStart.v
        let endVec = lineEnd.v
        
        // Vector from start to end
        let lineVec = endVec - startVec
        let lineLengthSq = lineVec.magnitudeSquaredSafe()
        
        // If line has zero length, return distance to start point
        if lineLengthSq == 0 {
            return pointVec.distance(to: startVec)
        }
        
        // Vector from start to point
        let pointVecRel = pointVec - startVec
        
        // Project point onto line
        let t = Float(pointVecRel.dot(lineVec)) / Float(lineLengthSq)
        
        // Clamp t to [0, 1] to stay on line segment
        let tClamped = max(0.0, min(1.0, t))
        
        // Find closest point on line segment
        let closestPoint = startVec + lineVec.scaled(by: tClamped)
        
        // Return distance from point to closest point on line
        return pointVec.distance(to: closestPoint)
    }
}
