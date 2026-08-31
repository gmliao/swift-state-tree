import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Movement System

/// Env keys for the movement perturbation hook (replay-scale-fp-perturbation experiment).
/// See Notes/plans/2026-08-31-replay-scale-fp-perturbation-experiment-design.md.
public enum MovementPerturbationEnvKeys {
    public static let tick = "HERO_PERTURB_TICK"
    public static let mode = "HERO_PERTURB_MODE"  // "float" | "fixed"
    public static let eps = "HERO_PERTURB_EPS"
}

/// Experiment-only perturbation configuration, read once per process.
/// All three env vars unset (the normal case) leaves movement fully untouched.
struct MovementPerturbation {
    let tick: Int64
    let mode: String
    let eps: Float

    static let current: MovementPerturbation? = {
        let env = ProcessInfo.processInfo.environment
        guard let t = env[MovementPerturbationEnvKeys.tick].flatMap({ Int64($0) }),
              let m = env[MovementPerturbationEnvKeys.mode],
              let e = env[MovementPerturbationEnvKeys.eps].flatMap({ Float($0) })
        else { return nil }
        return MovementPerturbation(tick: t, mode: m, eps: e)
    }()
}

/// System functions for movement logic
public enum MovementSystem {
    /// Clamp position to world bounds
    public static func clampToWorldBounds(_ position: Position2, _ ctx: LandContext) -> Position2 {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return position
        }
        let config = configService.provider
        let clampedX = max(0.0, min(config.worldWidth, Float(position.v.x) / 1000.0))
        let clampedY = max(0.0, min(config.worldHeight, Float(position.v.y) / 1000.0))
        return Position2(x: clampedX, y: clampedY)
    }
    
    /// Update player movement towards target position.
    /// Called every tick to move players with active targets.
    public static func updatePlayerMovement(
        _ player: inout PlayerState,
        _ ctx: LandContext,
        moveSpeed: Float = 1.0,
        arrivalThreshold: Float = 1.0
    ) {
        guard let target = player.targetPosition else {
            return
        }

        let current = player.position

        // Experiment hook: perturb the Float move speed before fixed-point quantization
        var effectiveMoveSpeed = moveSpeed
        if let p = MovementPerturbation.current, p.mode == "float", ctx.tickId == p.tick {
            effectiveMoveSpeed += p.eps
        }

        // Check if already reached target (using arrival threshold)
        if current.isWithinDistance(to: target, threshold: arrivalThreshold) {
            player.position = clampToWorldBounds(target, ctx)
            player.targetPosition = nil
            return
        }

        // Calculate rotation angle towards target (movement direction)
        let direction = target.v - current.v
        let angleRad = direction.toAngle()
        player.rotation = Angle(radians: angleRad)

        // Move towards target using Position2.moveTowards
        let newPosition = current.moveTowards(target: target, maxDistance: effectiveMoveSpeed)
        
        // Clamp to world bounds
        player.position = clampToWorldBounds(newPosition, ctx)

        // Experiment hook: shift the quantized x coordinate by eps raw LSB units (1 LSB = 0.001)
        if let p = MovementPerturbation.current, p.mode == "fixed", ctx.tickId == p.tick {
            // eps is in raw LSB units (1 LSB = 0.001 world units); eps/1000 quantizes back to exactly eps LSB
            player.position = Position2(v: player.position.v + IVec2(x: p.eps / 1000.0, y: 0.0))
        }

        // Check if reached target
        if newPosition == target {
            player.targetPosition = nil
        }
    }
    
    /// Update monster movement along path to base
    public static func updateMonsterMovement(
        _ monster: inout MonsterState,
        basePosition: Position2,
        _ ctx: LandContext
    ) {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return
        }
        let config = configService.provider
        
        let current = monster.position
        let target = basePosition
        
        // Calculate distance to base
        let distanceToBase = current.v.distance(to: target.v)
        
        // Check if reached base (within base radius)
        if distanceToBase <= config.baseRadius {
            monster.pathProgress = 1.0
            return
        }
        
        // Calculate direction to base
        let direction = target.v - current.v
        let angleRad = direction.toAngle()
        monster.rotation = Angle(radians: angleRad)
        
        // Move towards base
        let newPosition = current.moveTowards(target: target, maxDistance: config.monsterMoveSpeed)
        monster.position = newPosition
        
        // Update path progress (0.0 to 1.0)
        let totalDistance = monster.spawnPosition.v.distance(to: basePosition.v)
        if totalDistance > 0 {
            let traveledDistance = monster.spawnPosition.v.distance(to: newPosition.v)
            monster.pathProgress = min(1.0, traveledDistance / totalDistance)
        }
    }
}
