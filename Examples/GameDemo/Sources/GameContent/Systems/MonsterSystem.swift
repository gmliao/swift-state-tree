import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Monster System

/// System functions for monster spawning and AI
public enum MonsterSystem {
    /// Calculate current monster spawn interval based on game time
    /// Spawn speed increases over time, with a minimum interval limit
    public static func getMonsterSpawnInterval(_ ctx: LandContext) -> Int {
        guard let tickId = ctx.tickId,
              let configService = ctx.services.get(GameConfigProviderService.self) else {
            return 100  // Default fallback
        }
        let config = configService.provider
        let minInterval = Int64(config.monsterSpawnIntervalMinTicks)
        let maxInterval = Int64(config.monsterSpawnIntervalMaxTicks)
        let accelerationTicks = config.monsterSpawnAccelerationTicks
        
        // Calculate progress (0.0 to 1.0) towards maximum speed
        let progress = min(1.0, Float(tickId) / Float(accelerationTicks))
        
        // Linear interpolation from max to min interval
        let currentInterval = Float(maxInterval) - (Float(maxInterval - minInterval) * progress)
        
        // Clamp to ensure we don't go below minimum
        return max(Int(minInterval), Int(currentInterval))
    }
    
    /// Spawn a new monster at a random edge position
    public static func spawnMonster(
        nextID: Int,
        _ ctx: LandContext
    ) -> MonsterState {
        guard let configService = ctx.services.get(GameConfigProviderService.self),
              else {
            return MonsterState()
        }
        let config = configService.provider
        
        var monster = MonsterState()
        monster.id = nextID
        
        // Spawn at random edge position
        let edge = ctx.random.nextInt(in: 0..<4)  // 0=top, 1=right, 2=bottom, 3=left
        switch edge {
        case 0:  // Top
            monster.spawnPosition = Position2(
                x: ctx.random.nextFloat(in: 0..<config.worldWidth),
                y: 0.0
            )
        case 1:  // Right
            monster.spawnPosition = Position2(
                x: config.worldWidth,
                y: ctx.random.nextFloat(in: 0..<config.worldHeight)
            )
        case 2:  // Bottom
            monster.spawnPosition = Position2(
                x: ctx.random.nextFloat(in: 0..<config.worldWidth),
                y: config.worldHeight
            )
        case 3:  // Left
            monster.spawnPosition = Position2(
                x: 0.0,
                y: ctx.random.nextFloat(in: 0..<config.worldHeight)
            )
        default:
            monster.spawnPosition = Position2(x: 0.0, y: 0.0)
        }
        
        monster.position = monster.spawnPosition
        monster.pathProgress = 0.0
        monster.health = config.monsterBaseHealth
        monster.maxHealth = config.monsterBaseHealth
        monster.reward = config.monsterBaseReward
        
        return monster
    }
    
    /// Check if monster reached base and deal damage
    public static func checkMonsterReachedBase(
        _ monster: MonsterState,
        base: inout BaseState,
        _ ctx: LandContext
    ) -> Bool {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return false
        }
        let config = configService.provider
        let distance = monster.position.v.distance(to: base.position.v)
        if distance <= config.baseRadius {
            // Monster reached base, deal damage
            base.health = max(0, base.health - 1)
            return true
        }
        return false
    }
}
