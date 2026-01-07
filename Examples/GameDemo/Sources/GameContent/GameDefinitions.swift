import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Player State

/// Player state with position, rotation, and movement target.
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
    
    /// Example: shared game score
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
        self.target = Position2(x: x, y: y)
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
            }
            
            Lifetime {
                Tick(every: .milliseconds(50)) { (state: inout HeroDefenseState, ctx: LandContext) in
                    // Update player movement
                    var updatedCount = 0
                    var playersWithTarget = 0
                    
                    for (playerID, var player) in state.players {
                        guard let target = player.targetPosition else {
                            continue
                        }
                        
                        playersWithTarget += 1
                        let oldPosition = player.position
                        let current = player.position.v
                        let targetVec = target.v
                        
                        // Calculate direction vector
                        let direction = targetVec - current
                        // Use magnitudeSquaredSafe() to prevent Int32 overflow when squaring large values
                        let distSq = direction.magnitudeSquaredSafe()
                        
                        // Log distance calculation details
                        ctx.logger.debug("📏 Distance calculation", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "currentX": .string("\(current.floatX)"),
                            "currentY": .string("\(current.floatY)"),
                            "currentX_raw": .string("\(current.x)"),
                            "currentY_raw": .string("\(current.y)"),
                            "targetX": .string("\(targetVec.floatX)"),
                            "targetY": .string("\(targetVec.floatY)"),
                            "targetX_raw": .string("\(targetVec.x)"),
                            "targetY_raw": .string("\(targetVec.y)"),
                            "directionX": .string("\(direction.x)"),
                            "directionY": .string("\(direction.y)"),
                            "distSq": .string("\(distSq)"),
                            "distance": .string("\(sqrt(Double(distSq)) / 1000.0)")
                        ])
                        
                        // Check if reached target (within 1 unit = 1000 fixed-point)
                        let thresholdSq: Int64 = 1000 * 1000  // 1.0 unit squared
                        if distSq <= thresholdSq {
                            // Reached target - snap to exact target position for precision
                            player.position.v = targetVec
                            player.targetPosition = nil
                            ctx.logger.debug("🎯 Player reached target", metadata: [
                                "playerID": .string(playerID.rawValue),
                                "finalX": .string("\(player.position.v.floatX)"),
                                "finalY": .string("\(player.position.v.floatY)"),
                                "targetX": .string("\(targetVec.floatX)"),
                                "targetY": .string("\(targetVec.floatY)"),
                                "distSq": .string("\(distSq)"),
                                "thresholdSq": .string("\(thresholdSq)")
                            ])
                            state.players[playerID] = player
                            continue
                        }
                        
                        // Calculate rotation angle (in radians)
                        let angleRad = direction.toAngle()
                        // Convert to Angle (automatically quantized)
                        player.rotation = Angle(radians: angleRad)
                        
                        // Move towards target (speed: 1000 = 1.0 unit per tick = 10 units/second)
                        let moveSpeed: Int32 = 1000  // 1.0 unit per tick
                        let distance = Int32(sqrt(Double(distSq)))
                        let moveDistance = min(moveSpeed, distance)
                        
                        if moveDistance > 0 {
                            // If remaining distance is less than move speed, snap directly to target
                            if distance <= moveSpeed {
                                // Final step - move directly to target for precision
                                player.position.v = targetVec
                                player.targetPosition = nil
                                ctx.logger.debug("🎯 Player reached target (final step)", metadata: [
                                    "playerID": .string(playerID.rawValue),
                                    "finalX": .string("\(player.position.v.floatX)"),
                                    "finalY": .string("\(player.position.v.floatY)")
                                ])
                            } else {
                                // Normalize direction and scale by move distance
                                let normalized = direction.normalized()
                                let moveVec = IVec2(
                                    x: normalized.x * Float(moveDistance) / 1000.0,
                                    y: normalized.y * Float(moveDistance) / 1000.0
                                )
                                let newPosition = player.position.v + moveVec
                                player.position.v = newPosition
                            }
                            updatedCount += 1
                            
                            // Log movement every tick for first few moves, then every 10 ticks
                            // Only log if we actually moved (not when we snapped to target)
                            if (updatedCount <= 3 || updatedCount % 10 == 0) && distance > moveSpeed {
                                ctx.logger.debug("🚶 Player moving", metadata: [
                                    "playerID": .string(playerID.rawValue),
                                    "fromX": .string("\(oldPosition.v.floatX)"),
                                    "fromY": .string("\(oldPosition.v.floatY)"),
                                    "fromX_raw": .string("\(oldPosition.v.x)"),
                                    "fromY_raw": .string("\(oldPosition.v.y)"),
                                    "toX": .string("\(player.position.v.floatX)"),
                                    "toY": .string("\(player.position.v.floatY)"),
                                    "toX_raw": .string("\(player.position.v.x)"),
                                    "toY_raw": .string("\(player.position.v.y)"),
                                    "targetX": .string("\(target.v.floatX)"),
                                    "targetY": .string("\(target.v.floatY)"),
                                    "targetX_raw": .string("\(target.v.x)"),
                                    "targetY_raw": .string("\(target.v.y)"),
                                    "distance": .string("\(sqrt(Double(distSq)) / 1000.0)"),
                                    "moveDistance": .string("\(moveDistance)")
                                ])
                            }
                        } else {
                            ctx.logger.debug("⚠️ MoveDistance is 0", metadata: [
                                "playerID": .string(playerID.rawValue),
                                "distSq": .string("\(distSq)"),
                                "distance": .string("\(sqrt(Double(distSq)))"),
                                "moveSpeed": .string("\(moveSpeed)")
                            ])
                        }
                        
                        state.players[playerID] = player
                    }
                    
                    // Log tick summary every 20 ticks (every 1 second)
                    if updatedCount > 0 && (updatedCount % 20 == 0 || playersWithTarget > 0) {
                        ctx.logger.debug("⏱️ Tick summary", metadata: [
                            "totalPlayers": .string("\(state.players.count)"),
                            "playersWithTarget": .string("\(playersWithTarget)"),
                            "playersMoved": .string("\(updatedCount)")
                        ])
                    }
                }

                StateSync(every: .milliseconds(100)) { (state: HeroDefenseState, ctx: LandContext) in
                    // Read-only callback - will be called during sync
                    // Do NOT modify state here - use Tick for state mutations
                    // Use for logging, metrics, or other read-only operations
                    // StateSync callback - read-only operations only
                }
                
                DestroyWhenEmpty(after: .seconds(5)) { (_: inout HeroDefenseState, ctx: LandContext) in
                    ctx.logger.info("Hero Defense room is empty, destroying...")
                }
                
                OnFinalize { (state: inout HeroDefenseState, ctx: LandContext) in
                    ctx.logger.info("Hero Defense room is finalizing...")
                }
                
                AfterFinalize { (state: HeroDefenseState, ctx: LandContext) async in
                    ctx.logger.info("Hero Defense room is finalized with final score: \(state.score)")
                }
            }
            
            Rules {
                OnJoin { (state: inout HeroDefenseState, ctx: LandContext) in
                    let playerID = ctx.playerID
                    // Spawn player at center of world (64.0, 36.0 in world units)
                    var player = PlayerState()
                    player.position = Position2(x: 64.0, y: 36.0)
                    player.rotation = Angle(degrees: 0.0)
                    player.targetPosition = nil as Position2?
                    state.players[playerID] = player
                    ctx.logger.info("👤 Player joined", metadata: [
                        "playerID": .string(playerID.rawValue),
                        "initialX": .string("\(player.position.v.floatX)"),
                        "initialY": .string("\(player.position.v.floatY)"),
                        "initialX_raw": .string("\(player.position.v.x)"),
                        "initialY_raw": .string("\(player.position.v.y)"),
                        "totalPlayers": .string("\(state.players.count)")
                    ])
                }
                
                OnLeave { (state: inout HeroDefenseState, ctx: LandContext) in
                    let playerID = ctx.playerID
                    state.players.removeValue(forKey: playerID)
                    ctx.logger.info("Player left", metadata: [
                        "playerID": .string(playerID.rawValue)
                    ])
                }
                
                HandleAction(PlayAction.self) { (state: inout HeroDefenseState, action: PlayAction, ctx: LandContext) in
                    ctx.logger.info("🎮 PlayAction received", metadata: [
                        "playerID": .string(ctx.playerID.rawValue),
                        "currentScore": .string("\(state.score)")
                    ])
                    state.score += 1
                    let newScore = state.score
                    ctx.logger.info("✅ Score updated", metadata: [
                        "newScore": .string("\(newScore)")
                    ])
                    return PlayResponse(newScore: newScore)
                }
                
                HandleEvent(MoveToEvent.self) { (state: inout HeroDefenseState, event: MoveToEvent, ctx: LandContext) in
                    let playerID = ctx.playerID
                    
                    ctx.logger.debug("🔵 MoveToEvent handler called", metadata: [
                        "playerID": .string(playerID.rawValue),
                        "totalPlayers": .string("\(state.players.count)"),
                        "playerIDs": .string(state.players.keys.map { $0.rawValue }.joined(separator: ", "))
                    ])
                    
                    // Update player's target position
                    if var player = state.players[playerID] {
                        let oldTarget = player.targetPosition
                        let oldPosition = player.position
                        player.targetPosition = event.target
                        state.players[playerID] = player
                        ctx.logger.info("📥 MoveToEvent received", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "currentX": .string("\(player.position.v.floatX)"),
                            "currentY": .string("\(player.position.v.floatY)"),
                            "currentX_raw": .string("\(player.position.v.x)"),
                            "currentY_raw": .string("\(player.position.v.y)"),
                            "targetX": .string("\(event.target.v.floatX)"),
                            "targetY": .string("\(event.target.v.floatY)"),
                            "targetX_raw": .string("\(event.target.v.x)"),
                            "targetY_raw": .string("\(event.target.v.y)"),
                            "oldTarget": .string(oldTarget != nil ? "\(oldTarget!.v.floatX),\(oldTarget!.v.floatY)" : "nil"),
                            "targetPositionSet": .string("true")
                        ])
                    } else {
                        ctx.logger.warning("⚠️ MoveToEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "totalPlayers": .string("\(state.players.count)"),
                            "availablePlayerIDs": .string(state.players.keys.map { $0.rawValue }.joined(separator: ", "))
                        ])
                    }
                }
            }
        }
    }
}
