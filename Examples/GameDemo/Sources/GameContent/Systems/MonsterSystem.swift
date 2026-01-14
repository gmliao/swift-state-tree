import Foundation
import SwiftStateTreeDeterministicMath

// MARK: - Monster System

/// System functions for monster spawning and AI
public enum MonsterSystem {
    /// Calculate current monster spawn interval based on game time
    /// Spawn speed increases over time, with a minimum interval limit
    public static func getMonsterSpawnInterval(currentTick: Int64) -> Int {
        let minInterval = Int64(GameConfig.MONSTER_SPAWN_INTERVAL_MIN_TICKS)
        let maxInterval = Int64(GameConfig.MONSTER_SPAWN_INTERVAL_MAX_TICKS)
        let accelerationTicks = GameConfig.MONSTER_SPAWN_ACCELERATION_TICKS
        
        // Calculate progress (0.0 to 1.0) towards maximum speed
        let progress = min(1.0, Float(currentTick) / Float(accelerationTicks))
        
        // Linear interpolation from max to min interval
        let currentInterval = Float(maxInterval) - (Float(maxInterval - minInterval) * progress)
        
        // Clamp to ensure we don't go below minimum
        return max(Int(minInterval), Int(currentInterval))
    }
    
    /// Spawn a new monster at a random edge position
    public static func spawnMonster(nextID: Int) -> MonsterState {
        var monster = MonsterState()
        monster.id = nextID
        
        // Spawn at random edge position
        let edge = Int.random(in: 0..<4)  // 0=top, 1=right, 2=bottom, 3=left
        switch edge {
        case 0:  // Top
            monster.spawnPosition = Position2(
                x: Float.random(in: 0..<GameConfig.WORLD_WIDTH),
                y: 0.0
            )
        case 1:  // Right
            monster.spawnPosition = Position2(
                x: GameConfig.WORLD_WIDTH,
                y: Float.random(in: 0..<GameConfig.WORLD_HEIGHT)
            )
        case 2:  // Bottom
            monster.spawnPosition = Position2(
                x: Float.random(in: 0..<GameConfig.WORLD_WIDTH),
                y: GameConfig.WORLD_HEIGHT
            )
        case 3:  // Left
            monster.spawnPosition = Position2(
                x: 0.0,
                y: Float.random(in: 0..<GameConfig.WORLD_HEIGHT)
            )
        default:
            monster.spawnPosition = Position2(x: 0.0, y: 0.0)
        }
        
        monster.position = monster.spawnPosition
        monster.pathProgress = 0.0
        monster.health = GameConfig.MONSTER_BASE_HEALTH
        monster.maxHealth = GameConfig.MONSTER_BASE_HEALTH
        monster.reward = GameConfig.MONSTER_BASE_REWARD
        
        return monster
    }
    
    /// Check if monster reached base and deal damage
    public static func checkMonsterReachedBase(
        _ monster: MonsterState,
        base: inout BaseState
    ) -> Bool {
        let distance = monster.position.v.distance(to: base.position.v)
        if distance <= GameConfig.BASE_RADIUS {
            // Monster reached base, deal damage
            base.health = max(0, base.health - 1)
            return true
        }
        return false
    }
}
