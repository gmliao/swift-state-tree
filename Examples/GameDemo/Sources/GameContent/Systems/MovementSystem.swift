import Foundation
import SwiftStateTreeDeterministicMath

// MARK: - Movement System

/// System functions for movement logic
public enum MovementSystem {
    /// Clamp position to world bounds
    public static func clampToWorldBounds(_ position: Position2) -> Position2 {
        let clampedX = max(0.0, min(GameConfig.WORLD_WIDTH, Float(position.v.x) / 1000.0))
        let clampedY = max(0.0, min(GameConfig.WORLD_HEIGHT, Float(position.v.y) / 1000.0))
        return Position2(x: clampedX, y: clampedY)
    }
    
    /// Update player movement towards target position.
    /// Called every tick to move players with active targets.
    public static func updatePlayerMovement(
        _ player: inout PlayerState,
        moveSpeed: Float = 1.0,
        arrivalThreshold: Float = 1.0
    ) {
        guard let target = player.targetPosition else {
            return
        }

        let current = player.position

        // Check if already reached target (using arrival threshold)
        if current.isWithinDistance(to: target, threshold: arrivalThreshold) {
            player.position = clampToWorldBounds(target)
            player.targetPosition = nil
            return
        }

        // Calculate rotation angle towards target (movement direction)
        let direction = target.v - current.v
        let angleRad = direction.toAngle()
        player.rotation = Angle(radians: angleRad)

        // Move towards target using Position2.moveTowards
        let newPosition = current.moveTowards(target: target, maxDistance: moveSpeed)
        
        // Clamp to world bounds
        player.position = clampToWorldBounds(newPosition)

        // Check if reached target
        if newPosition == target {
            player.targetPosition = nil
        }
    }
    
    /// Update monster movement along path to base
    public static func updateMonsterMovement(
        _ monster: inout MonsterState,
        basePosition: Position2
    ) {
        let current = monster.position
        let target = basePosition
        
        // Calculate distance to base
        let distanceToBase = current.v.distance(to: target.v)
        
        // Check if reached base (within base radius)
        if distanceToBase <= GameConfig.BASE_RADIUS {
            monster.pathProgress = 1.0
            return
        }
        
        // Calculate direction to base
        let direction = target.v - current.v
        let angleRad = direction.toAngle()
        monster.rotation = Angle(radians: angleRad)
        
        // Move towards base
        let newPosition = current.moveTowards(target: target, maxDistance: GameConfig.MONSTER_MOVE_SPEED)
        monster.position = newPosition
        
        // Update path progress (0.0 to 1.0)
        let totalDistance = monster.spawnPosition.v.distance(to: basePosition.v)
        if totalDistance > 0 {
            let traveledDistance = monster.spawnPosition.v.distance(to: newPosition.v)
            monster.pathProgress = min(1.0, traveledDistance / totalDistance)
        }
    }
}
