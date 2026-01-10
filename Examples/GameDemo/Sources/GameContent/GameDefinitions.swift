import Foundation
import Logging
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Game Constants

/// Game world configuration constants
public enum GameConfig {
    /// World size limits (in Float units)
    public static let WORLD_WIDTH: Float = 128.0
    public static let WORLD_HEIGHT: Float = 72.0
    
    /// Base position (center of world)
    public static let BASE_CENTER_X: Float = WORLD_WIDTH / 2.0
    public static let BASE_CENTER_Y: Float = WORLD_HEIGHT / 2.0
    public static let BASE_RADIUS: Float = 3.0
    
    /// Base health
    public static let BASE_MAX_HEALTH: Int = 100
    
    /// Monster spawn configuration
    public static let MONSTER_SPAWN_INTERVAL_TICKS: Int = 50  // 5 seconds at 50ms/tick (initial)
    public static let MONSTER_SPAWN_INTERVAL_MIN_TICKS: Int = 5  // 1 second at 50ms/tick (fastest, upper limit)
    public static let MONSTER_SPAWN_INTERVAL_MAX_TICKS: Int = 50  // 5 seconds at 50ms/tick (slowest, initial)
    public static let MONSTER_SPAWN_ACCELERATION_TICKS: Int64 = 6000  // 300 seconds (5 minutes) to reach max speed
    public static let MONSTER_MOVE_SPEED: Float = 0.5
    public static let MONSTER_BASE_HEALTH: Int = 10
    public static let MONSTER_BASE_REWARD: Int = 1
    
    /// Weapon configuration
    public static let WEAPON_BASE_DAMAGE: Int = 5
    public static let WEAPON_BASE_RANGE: Float = 20.0
    public static let WEAPON_FIRE_RATE_TICKS: Int = 10  // 0.5 seconds at 50ms/tick
    
    /// Turret configuration
    public static let TURRET_BASE_DAMAGE: Int = 3
    public static let TURRET_BASE_RANGE: Float = 15.0
    public static let TURRET_FIRE_RATE_TICKS: Int = 20  // 1 second at 50ms/tick
    public static let TURRET_PLACEMENT_DISTANCE: Float = 8.0  // Distance from base center
    
    /// Upgrade costs
    public static let WEAPON_UPGRADE_COST: Int = 5
    public static let TURRET_UPGRADE_COST: Int = 10
    public static let TURRET_PLACEMENT_COST: Int = 15
}

// MARK: - Player State

/// Player state with position, rotation, movement, weapon, and resources.
@StateNodeBuilder
public struct PlayerState: StateNodeProtocol {
    /// Player position in 2D world (fixed-point: 1000 = 1.0)
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0.0, y: 0.0)

    /// Player rotation angle
    @Sync(.broadcast)
    var rotation: Angle = Angle(degrees: 0.0)

    /// Target position for movement (nil when not moving)
    @Sync(.broadcast)
    var targetPosition: Position2? = nil
    
    /// Player health
    @Sync(.broadcast)
    var health: Int = 100
    
    /// Player max health
    @Sync(.broadcast)
    var maxHealth: Int = 100
    
    /// Weapon level (0 = base)
    @Sync(.broadcast)
    var weaponLevel: Int = 0
    
    /// Resources (earned from defeating monsters)
    @Sync(.broadcast)
    var resources: Int = 0
    
    /// Last fire tick (for fire rate limiting)
    @Sync(.serverOnly)
    var lastFireTick: Int64 = 0

    public init() {}
}

// MARK: - Monster State

/// Monster state with position, path progress, and health.
@StateNodeBuilder
public struct MonsterState: StateNodeProtocol {
    /// Unique monster ID
    @Sync(.broadcast)
    var id: Int = 0
    
    /// Monster position in 2D world
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0.0, y: 0.0)
    
    /// Monster rotation angle (facing direction)
    @Sync(.broadcast)
    var rotation: Angle = Angle(degrees: 0.0)
    
    /// Current health
    @Sync(.broadcast)
    var health: Int = GameConfig.MONSTER_BASE_HEALTH
    
    /// Max health
    @Sync(.broadcast)
    var maxHealth: Int = GameConfig.MONSTER_BASE_HEALTH
    
    /// Spawn position (for path calculation)
    @Sync(.serverOnly)
    var spawnPosition: Position2 = Position2(x: 0.0, y: 0.0)
    
    /// Path progress (0.0 to 1.0, where 1.0 = reached base)
    @Sync(.serverOnly)
    var pathProgress: Float = 0.0
    
    /// Resource reward when defeated
    @Sync(.serverOnly)
    var reward: Int = GameConfig.MONSTER_BASE_REWARD
    
    public init() {}
}

// MARK: - Turret State

/// Turret state with position, level, and targeting.
@StateNodeBuilder
public struct TurretState: StateNodeProtocol {
    /// Unique turret ID
    @Sync(.broadcast)
    var id: Int = 0
    
    /// Turret position in 2D world
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0.0, y: 0.0)
    
    /// Turret rotation angle (facing direction)
    @Sync(.broadcast)
    var rotation: Angle = Angle(degrees: 0.0)
    
    /// Turret level (0 = base)
    @Sync(.broadcast)
    var level: Int = 0
    
    /// Last fire tick (for fire rate limiting)
    @Sync(.serverOnly)
    var lastFireTick: Int64 = 0
    
    /// Owner player ID (who placed this turret)
    @Sync(.broadcast)
    var ownerID: PlayerID? = nil
    
    public init() {}
}

// MARK: - Base State

/// Base/fortress state at world center.
@StateNodeBuilder
public struct BaseState: StateNodeProtocol {
    /// Base position (center of world)
    @Sync(.broadcast)
    var position: Position2 = Position2(x: GameConfig.BASE_CENTER_X, y: GameConfig.BASE_CENTER_Y)
    
    /// Base radius
    @Sync(.broadcast)
    var radius: Float = GameConfig.BASE_RADIUS
    
    /// Current health
    @Sync(.broadcast)
    var health: Int = GameConfig.BASE_MAX_HEALTH
    
    /// Max health
    @Sync(.broadcast)
    var maxHealth: Int = GameConfig.BASE_MAX_HEALTH
    
    public init() {}
}

// MARK: - Game State

/// Hero Defense game state definition.
/// Players can move freely, shoot monsters, and upgrade with resources.
@StateNodeBuilder
public struct HeroDefenseState: StateNodeProtocol {
    /// Online players and their states
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]

    /// Active monsters in the world
    @Sync(.broadcast)
    var monsters: [Int: MonsterState] = [:]

    /// Placed turrets
    @Sync(.broadcast)
    var turrets: [Int: TurretState] = [:]
    
    /// Next monster ID counter (for generating unique IDs)
    @Sync(.serverOnly)
    var nextMonsterID: Int = 1
    
    /// Next turret ID counter (for generating unique IDs)
    @Sync(.serverOnly)
    var nextTurretID: Int = 1

    /// Base/fortress state
    @Sync(.broadcast)
    var base: BaseState = BaseState()

    /// Shared game score
    @Sync(.broadcast)
    var score: Int = 0

    public init() {}
}

// MARK: - Actions

/// Example action to play the game.
@Payload
public struct PlayAction: ActionPayload {
    public typealias Response = PlayResponse

    public init() {}
}

@Payload
public struct PlayResponse: ResponsePayload {
    public let newScore: Int

    public init(newScore: Int) {
        self.newScore = newScore
    }
}

// MARK: - Events

/// Client event to move player to a target position.
@Payload
public struct MoveToEvent: ClientEventPayload {
    public let target: Position2

    public init(target: Position2) {
        self.target = target
    }

    /// Convenience initializer from Float coordinates
    public init(x: Float, y: Float) {
        target = Position2(x: x, y: y)
    }
}

/// Client event to shoot (uses current rotation/aiming direction).
@Payload
public struct ShootEvent: ClientEventPayload {
    public init() {}
}

/// Client event to update player rotation (facing direction).
@Payload
public struct UpdateRotationEvent: ClientEventPayload {
    public let rotation: Angle

    public init(rotation: Angle) {
        self.rotation = rotation
    }

    /// Convenience initializer from radians
    public init(radians: Float) {
        rotation = Angle(radians: radians)
    }
}

/// Client event to place a turret at a position.
@Payload
public struct PlaceTurretEvent: ClientEventPayload {
    public let position: Position2

    public init(position: Position2) {
        self.position = position
    }

    /// Convenience initializer from Float coordinates
    public init(x: Float, y: Float) {
        position = Position2(x: x, y: y)
    }
}

/// Client event to upgrade weapon.
@Payload
public struct UpgradeWeaponEvent: ClientEventPayload {
    public init() {}
}

/// Client event to upgrade a turret.
@Payload
public struct UpgradeTurretEvent: ClientEventPayload {
    public let turretID: Int

    public init(turretID: Int) {
        self.turretID = turretID
    }
}

// MARK: - Server Events

/// Server event broadcasted when a player shoots.
@Payload
public struct PlayerShootEvent: ServerEventPayload {
    public let playerID: PlayerID
    public let from: Position2
    public let to: Position2

    public init(playerID: PlayerID, from: Position2, to: Position2) {
        self.playerID = playerID
        self.from = from
        self.to = to
    }
}

/// Server event broadcasted when a turret fires.
@Payload
public struct TurretFireEvent: ServerEventPayload {
    public let turretID: Int
    public let from: Position2
    public let to: Position2

    public init(turretID: Int, from: Position2, to: Position2) {
        self.turretID = turretID
        self.from = from
        self.to = to
    }
}

// MARK: - Game Systems

/// System functions for game logic (movement, combat, etc.)
/// These are pure functions that can be unit tested independently.
enum GameSystem {
    // MARK: - World Bounds
    
    /// Clamp position to world bounds
    static func clampToWorldBounds(_ position: Position2) -> Position2 {
        let clampedX = max(0.0, min(GameConfig.WORLD_WIDTH, Float(position.v.x) / 1000.0))
        let clampedY = max(0.0, min(GameConfig.WORLD_HEIGHT, Float(position.v.y) / 1000.0))
        return Position2(x: clampedX, y: clampedY)
    }
    
    // MARK: - Player Systems
    
    /// Update player movement towards target position.
    /// Called every tick to move players with active targets.
    static func updatePlayerMovement(
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
    
    /// Calculate weapon damage based on level
    static func getWeaponDamage(level: Int) -> Int {
        return GameConfig.WEAPON_BASE_DAMAGE + (level * 2)
    }
    
    /// Calculate weapon range based on level
    static func getWeaponRange(level: Int) -> Float {
        return GameConfig.WEAPON_BASE_RANGE + (Float(level) * 2.0)
    }
    
    /// Check if player can fire (fire rate check)
    static func canPlayerFire(_ player: PlayerState, currentTick: Int64) -> Bool {
        let fireRate = Int64(GameConfig.WEAPON_FIRE_RATE_TICKS)
        return currentTick - player.lastFireTick >= fireRate
    }
    
    /// Find nearest monster within range
    static func findNearestMonsterInRange(
        from position: Position2,
        range: Float,
        monsters: [Int: MonsterState]
    ) -> (id: Int, monster: MonsterState)? {
        var nearest: (id: Int, monster: MonsterState)? = nil
        var nearestDistance: Float = Float.greatestFiniteMagnitude
        
        for (id, monster) in monsters {
            let distance = position.v.distance(to: monster.position.v)
            if distance <= range && distance < nearestDistance {
                nearest = (id, monster)
                nearestDistance = distance
            }
        }
        
        return nearest
    }
    
    // MARK: - Monster Systems
    
    /// Calculate current monster spawn interval based on game time
    /// Spawn speed increases over time, with a minimum interval limit
    static func getMonsterSpawnInterval(currentTick: Int64) -> Int {
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
    static func spawnMonster(nextID: Int) -> MonsterState {
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
    
    /// Update monster movement along path to base
    static func updateMonsterMovement(
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
    
    /// Check if monster reached base and deal damage
    static func checkMonsterReachedBase(
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
    
    // MARK: - Turret Systems
    
    /// Calculate turret damage based on level
    static func getTurretDamage(level: Int) -> Int {
        return GameConfig.TURRET_BASE_DAMAGE + (level * 1)
    }
    
    /// Calculate turret range based on level
    static func getTurretRange(level: Int) -> Float {
        return GameConfig.TURRET_BASE_RANGE + (Float(level) * 1.0)
    }
    
    /// Check if turret can fire (fire rate check)
    static func canTurretFire(_ turret: TurretState, currentTick: Int64) -> Bool {
        let fireRate = Int64(GameConfig.TURRET_FIRE_RATE_TICKS)
        return currentTick - turret.lastFireTick >= fireRate
    }
    
    /// Find nearest monster within turret range
    static func findNearestMonsterInTurretRange(
        from position: Position2,
        range: Float,
        monsters: [Int: MonsterState]
    ) -> (id: Int, monster: MonsterState)? {
        return findNearestMonsterInRange(from: position, range: range, monsters: monsters)
    }
    
    /// Check if position is valid for turret placement
    static func isValidTurretPosition(
        _ position: Position2,
        basePosition: Position2,
        existingTurrets: [Int: TurretState]
    ) -> Bool {
        // Check distance from base
        let distanceFromBase = position.v.distance(to: basePosition.v)
        if distanceFromBase < GameConfig.TURRET_PLACEMENT_DISTANCE {
            return false
        }
        
        // Check if too close to existing turrets
        for (_, turret) in existingTurrets {
            let distance = position.v.distance(to: turret.position.v)
            if distance < 3.0 {  // Minimum spacing
                return false
            }
        }
        
        // Check world bounds (convert from fixed-point to Float)
        let posX = Float(position.v.x) / 1000.0
        let posY = Float(position.v.y) / 1000.0
        if posX < 0 || posX > GameConfig.WORLD_WIDTH ||
           posY < 0 || posY > GameConfig.WORLD_HEIGHT {
            return false
        }
        
        return true
    }
    
    // MARK: - Combat Systems
    
    /// Apply damage to monster (returns true if monster is defeated)
    static func damageMonster(_ monster: inout MonsterState, damage: Int) -> Bool {
        monster.health = max(0, monster.health - damage)
        return monster.health <= 0
    }
    
    /// Calculate distance from a point to a line segment
    static func distanceToLineSegment(
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
        // scaled(by:) expects Float, not Int32
        let closestPoint = startVec + lineVec.scaled(by: tClamped)
        
        // Return distance from point to closest point on line
        return pointVec.distance(to: closestPoint)
    }
}

// MARK: - Land Definition

public enum HeroDefense {
    public static func makeLand() -> LandDefinition<HeroDefenseState> {
        Land(
            "hero-defense",
            using: HeroDefenseState.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(10)
            }

            ClientEvents {
                Register(MoveToEvent.self)
                Register(ShootEvent.self)
                Register(UpdateRotationEvent.self)
                Register(PlaceTurretEvent.self)
                Register(UpgradeWeaponEvent.self)
                Register(UpgradeTurretEvent.self)
            }

            ServerEvents {
                Register(PlayerShootEvent.self)
                Register(TurretFireEvent.self)
            }

            Lifetime {
                Tick(every: .milliseconds(50)) { (state: inout HeroDefenseState, ctx: LandContext) in
                    guard let tickId = ctx.tickId else { return }
                    
                    // Update all player systems
                    for (playerID, var player) in state.players {
                        // Update movement (this also updates rotation towards movement target)
                        GameSystem.updatePlayerMovement(&player)
                        
                        // Auto-shoot: Check if there's a monster in range and fire automatically
                        if GameSystem.canPlayerFire(player, currentTick: tickId) {
                            let range = GameSystem.getWeaponRange(level: player.weaponLevel)
                            let nearestMonster = GameSystem.findNearestMonsterInRange(
                                from: player.position,
                                range: range,
                                monsters: state.monsters
                            )
                            
                            if let (monsterID, monster) = nearestMonster {
                                // Rotate player towards monster (auto-aim)
                                let direction = monster.position.v - player.position.v
                                let angleRad = direction.toAngle()
                                player.rotation = Angle(radians: angleRad)
                                
                                // Save positions for event (before mutation)
                                let playerPos = player.position
                                let monsterPos = monster.position
                                
                                // Apply damage
                                var updatedMonster = monster
                                let damage = GameSystem.getWeaponDamage(level: player.weaponLevel)
                                if GameSystem.damageMonster(&updatedMonster, damage: damage) {
                                    // Monster defeated, give resources
                                    player.resources += updatedMonster.reward
                                    state.monsters.removeValue(forKey: monsterID)
                                } else {
                                    state.monsters[monsterID] = updatedMonster
                                }
                                
                                player.lastFireTick = tickId
                                
                                // Broadcast shoot event to all players
                                ctx.spawn {
                                    await ctx.sendEvent(
                                        PlayerShootEvent(
                                            playerID: playerID,
                                            from: playerPos,
                                            to: monsterPos
                                        ),
                                        to: .all
                                    )
                                }
                            }
                        }
                        
                        state.players[playerID] = player
                    }
                    
                    // Spawn monsters periodically (spawn speed increases over time)
                    let spawnInterval = GameSystem.getMonsterSpawnInterval(currentTick: tickId)
                    if tickId % Int64(spawnInterval) == 0 {
                        let monsterID = state.nextMonsterID
                        state.nextMonsterID += 1
                        let monster = GameSystem.spawnMonster(nextID: monsterID)
                        state.monsters[monster.id] = monster
                    }
                    
                    // Update all monsters
                    var monstersToRemove: [Int] = []
                    for (monsterID, var monster) in state.monsters {
                        // Update movement
                        GameSystem.updateMonsterMovement(&monster, basePosition: state.base.position)
                        state.monsters[monsterID] = monster
                        
                        // Check if reached base
                        if GameSystem.checkMonsterReachedBase(monster, base: &state.base) {
                            monstersToRemove.append(monsterID)
                        }
                    }
                    
                    // Remove monsters that reached base
                    for monsterID in monstersToRemove {
                        state.monsters.removeValue(forKey: monsterID)
                    }
                    
                    // Update turrets (auto-target and fire)
                    for (turretID, var turret) in state.turrets {
                        if GameSystem.canTurretFire(turret, currentTick: tickId) {
                            let range = GameSystem.getTurretRange(level: turret.level)
                            let nearestMonster = GameSystem.findNearestMonsterInTurretRange(
                                from: turret.position,
                                range: range,
                                monsters: state.monsters
                            )
                            if let (monsterID, monster) = nearestMonster {
                                // Rotate turret towards target
                                let direction = monster.position.v - turret.position.v
                                let angleRad = direction.toAngle()
                                turret.rotation = Angle(radians: angleRad)
                                
                                // Save positions for event (before mutation)
                                let turretPos = turret.position
                                let monsterPos = monster.position
                                
                                // Fire at monster
                                var updatedMonster = monster
                                let damage = GameSystem.getTurretDamage(level: turret.level)
                                if GameSystem.damageMonster(&updatedMonster, damage: damage) {
                                    // Monster defeated, give resources to turret owner
                                    if let ownerID = turret.ownerID,
                                       var owner = state.players[ownerID] {
                                        owner.resources += updatedMonster.reward
                                        state.players[ownerID] = owner
                                    }
                                    state.monsters.removeValue(forKey: monsterID)
                                } else {
                                    state.monsters[monsterID] = updatedMonster
                                }
                                
                                turret.lastFireTick = tickId
                                
                                // Broadcast turret fire event to all players
                                ctx.spawn {
                                    await ctx.sendEvent(
                                        TurretFireEvent(
                                            turretID: turretID,
                                            from: turretPos,
                                            to: monsterPos
                                        ),
                                        to: .all
                                    )
                                }
                            }
                        }
                        state.turrets[turretID] = turret
                    }
                }

                StateSync(every: .milliseconds(100)) { (_: HeroDefenseState, _: LandContext) in
                    // Read-only callback - will be called during sync
                    // Do NOT modify state here - use Tick for state mutations
                    // Use for logging, metrics, or other read-only operations
                    // StateSync callback - read-only operations only
                }

                DestroyWhenEmpty(after: .seconds(5)) { (_: inout HeroDefenseState, ctx: LandContext) in
                    ctx.logger.info("Hero Defense room is empty, destroying...")
                }

                OnFinalize { (_: inout HeroDefenseState, ctx: LandContext) in
                    ctx.logger.info("Hero Defense room is finalizing...")
                }

                AfterFinalize { (state: HeroDefenseState, ctx: LandContext) async in
                    ctx.logger.info("Hero Defense room is finalized with final score: \(state.score)")
                }
            }

            Rules {
                OnJoin { (state: inout HeroDefenseState, ctx: LandContext) in
                    let playerID = ctx.playerID
                    // Spawn player near base center
                    var player = PlayerState()
                    player.position = Position2(
                        x: GameConfig.BASE_CENTER_X + Float.random(in: -5.0..<5.0),
                        y: GameConfig.BASE_CENTER_Y + Float.random(in: -5.0..<5.0)
                    )
                    player.position = GameSystem.clampToWorldBounds(player.position)
                    player.rotation = Angle(degrees: 0.0)
                    player.targetPosition = nil as Position2?
                    player.health = 100
                    player.maxHealth = 100
                    player.weaponLevel = 0
                    player.resources = 0
                    state.players[playerID] = player
                    ctx.logger.info("👤 Player joined", metadata: [
                        "playerID": .string(playerID.rawValue),
                        "totalPlayers": .string("\(state.players.count)"),
                    ])
                }

                OnLeave { (state: inout HeroDefenseState, ctx: LandContext) in
                    let playerID = ctx.playerID
                    state.players.removeValue(forKey: playerID)
                    ctx.logger.info("Player left", metadata: [
                        "playerID": .string(playerID.rawValue),
                    ])
                }

                HandleAction(PlayAction.self) { (state: inout HeroDefenseState, _: PlayAction, ctx: LandContext) in
                    state.score += 1
                    return PlayResponse(newScore: state.score)
                }

                HandleEvent(MoveToEvent.self) { (state: inout HeroDefenseState, event: MoveToEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    // Update player's target position (clamp to world bounds)
                    if var player = state.players[playerID] {
                        let clampedTarget = GameSystem.clampToWorldBounds(event.target)
                        player.targetPosition = clampedTarget
                        state.players[playerID] = player
                    } else {
                        ctx.logger.warning("⚠️ MoveToEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                    }
                }
                
                HandleEvent(ShootEvent.self) { (state: inout HeroDefenseState, event: ShootEvent, ctx: LandContext) in
                    // Manual shoot event (optional - auto-shoot is handled in Tick)
                    // This can be used for manual shooting if needed in the future
                    let playerID = ctx.playerID
                    
                    guard var player = state.players[playerID],
                          let tickId = ctx.tickId else {
                        ctx.logger.warning("⚠️ ShootEvent: Player not found or tickId unavailable", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }
                    
                    // Check fire rate
                    if !GameSystem.canPlayerFire(player, currentTick: tickId) {
                        return
                    }
                    
                    // Find nearest monster in range and auto-aim
                    let range = GameSystem.getWeaponRange(level: player.weaponLevel)
                    let nearestMonster = GameSystem.findNearestMonsterInRange(
                        from: player.position,
                        range: range,
                        monsters: state.monsters
                    )
                    
                    if let (monsterID, monster) = nearestMonster {
                        // Rotate player towards monster (auto-aim)
                        let direction = monster.position.v - player.position.v
                        let angleRad = direction.toAngle()
                        player.rotation = Angle(radians: angleRad)
                        
                        // Save positions for event (before mutation)
                        let playerPos = player.position
                        let monsterPos = monster.position
                        
                        // Apply damage
                        var updatedMonster = monster
                        let damage = GameSystem.getWeaponDamage(level: player.weaponLevel)
                        if GameSystem.damageMonster(&updatedMonster, damage: damage) {
                            // Monster defeated, give resources
                            player.resources += updatedMonster.reward
                            state.monsters.removeValue(forKey: monsterID)
                        } else {
                            state.monsters[monsterID] = updatedMonster
                        }
                        
                        player.lastFireTick = tickId
                        
                        // Broadcast shoot event
                        ctx.spawn {
                            await ctx.sendEvent(
                                PlayerShootEvent(
                                    playerID: playerID,
                                    from: playerPos,
                                    to: monsterPos
                                ),
                                to: .all
                            )
                        }
                    }
                    
                    state.players[playerID] = player
                }
                
                HandleEvent(UpdateRotationEvent.self) { (state: inout HeroDefenseState, event: UpdateRotationEvent, ctx: LandContext) in
                    let playerID = ctx.playerID
                    
                    guard var player = state.players[playerID] else {
                        ctx.logger.warning("⚠️ UpdateRotationEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }
                    
                    // Update player rotation
                    player.rotation = event.rotation
                    state.players[playerID] = player
                }
                
                HandleEvent(PlaceTurretEvent.self) { (state: inout HeroDefenseState, event: PlaceTurretEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    guard var player = state.players[playerID] else {
                        ctx.logger.warning("⚠️ PlaceTurretEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }

                    // Check if player has enough resources
                    if player.resources < GameConfig.TURRET_PLACEMENT_COST {
                        ctx.logger.info("⚠️ PlaceTurretEvent: Insufficient resources", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "required": .string("\(GameConfig.TURRET_PLACEMENT_COST)"),
                            "available": .string("\(player.resources)"),
                        ])
                        return
                    }

                    // Check if position is valid
                    if !GameSystem.isValidTurretPosition(
                        event.position,
                        basePosition: state.base.position,
                        existingTurrets: state.turrets
                    ) {
                        ctx.logger.info("⚠️ PlaceTurretEvent: Invalid position", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }

                    // Deduct resources and place turret
                    player.resources -= GameConfig.TURRET_PLACEMENT_COST
                    let turretID = state.nextTurretID
                    state.nextTurretID += 1
                    var turret = TurretState()
                    turret.id = turretID
                    turret.position = event.position
                    turret.ownerID = playerID
                    turret.level = 0
                    state.turrets[turret.id] = turret
                    state.players[playerID] = player

                    ctx.logger.info("🏰 Turret placed", metadata: [
                        "playerID": .string(playerID.rawValue),
                        "turretID": .string("\(turret.id)"),
                        "cost": .string("\(GameConfig.TURRET_PLACEMENT_COST)"),
                        "remainingResources": .string("\(player.resources)"),
                    ])
                }
                
                HandleEvent(UpgradeWeaponEvent.self) { (state: inout HeroDefenseState, event: UpgradeWeaponEvent, ctx: LandContext) in
                    let playerID = ctx.playerID
                    
                    guard var player = state.players[playerID] else {
                        ctx.logger.warning("⚠️ UpgradeWeaponEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }
                    
                    // Check if player has enough resources
                    if player.resources >= GameConfig.WEAPON_UPGRADE_COST {
                        player.resources -= GameConfig.WEAPON_UPGRADE_COST
                        player.weaponLevel += 1
                        state.players[playerID] = player
                        
                        ctx.logger.info("🔫 Weapon upgraded", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "level": .string("\(player.weaponLevel)"),
                        ])
                    }
                }
                
                HandleEvent(UpgradeTurretEvent.self) { (state: inout HeroDefenseState, event: UpgradeTurretEvent, ctx: LandContext) in
                    let playerID = ctx.playerID
                    
                    guard var player = state.players[playerID],
                          var turret = state.turrets[event.turretID] else {
                        ctx.logger.warning("⚠️ UpgradeTurretEvent: Player or turret not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "turretID": .string("\(event.turretID)"),
                        ])
                        return
                    }
                    
                    // Check ownership
                    guard turret.ownerID == playerID else {
                        ctx.logger.warning("⚠️ UpgradeTurretEvent: Not owner", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "turretID": .string("\(event.turretID)"),
                        ])
                        return
                    }
                    
                    // Check if player has enough resources
                    if player.resources >= GameConfig.TURRET_UPGRADE_COST {
                        player.resources -= GameConfig.TURRET_UPGRADE_COST
                        turret.level += 1
                        state.players[playerID] = player
                        state.turrets[event.turretID] = turret
                        
                        ctx.logger.info("🏰 Turret upgraded", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "turretID": .string("\(event.turretID)"),
                            "level": .string("\(turret.level)"),
                        ])
                    }
                }
            }
        }
    }
}
