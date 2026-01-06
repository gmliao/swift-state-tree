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
                    for (playerID, var player) in state.players {
                        guard let target = player.targetPosition else {
                            continue
                        }
                        
                        let current = player.position.v
                        let targetVec = target.v
                        
                        // Calculate direction vector
                        let direction = targetVec - current
                        let distSq = direction.magnitudeSquared()
                        
                        // Check if reached target (within 1 unit = 1000 fixed-point)
                        let thresholdSq: Int64 = 1000 * 1000  // 1.0 unit squared
                        if distSq <= thresholdSq {
                            // Reached target
                            player.targetPosition = nil
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
                            // Normalize direction and scale by move distance
                            let normalized = direction.normalized()
                            let moveVec = IVec2(
                                x: normalized.x * Float(moveDistance) / 1000.0,
                                y: normalized.y * Float(moveDistance) / 1000.0
                            )
                            player.position.v = player.position.v + moveVec
                        }
                        
                        state.players[playerID] = player
                    }
                }

                StateSync(every: .milliseconds(100)) { (state: HeroDefenseState, ctx: LandContext) in
                    // Read-only callback - will be called during sync
                    // Do NOT modify state here - use Tick for state mutations
                    // Use for logging, metrics, or other read-only operations
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
                    ctx.logger.info("Player joined", metadata: [
                        "playerID": .string(playerID.rawValue)
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
                    
                    // Update player's target position
                    if var player = state.players[playerID] {
                        player.targetPosition = event.target
                        state.players[playerID] = player
                        ctx.logger.info("MoveToEvent received", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "targetX": .string("\(event.target.v.floatX)"),
                            "targetY": .string("\(event.target.v.floatY)")
                        ])
                    }
                }
            }
        }
    }
}
