import Foundation
import Logging
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
        target = Position2(x: x, y: y)
    }
}

// MARK: - Game Systems

/// System functions for game logic (movement, combat, etc.)
/// These are pure functions that can be unit tested independently.
enum GameSystem {
    /// Update player movement towards target position.
    /// Called every tick to move players with active targets.
    ///
    /// - Parameters:
    ///   - player: The player state to update (inout).
    ///   - moveSpeed: Movement speed in Float units per tick (default: 1.0).
    ///   - arrivalThreshold: Distance threshold to consider target reached in Float units (default: 1.0).
    ///
    /// This function handles:
    /// - Distance calculation and arrival detection
    /// - Rotation towards target
    /// - Movement with proper normalization handling
    /// - Edge cases (normalization failure, very small distances)
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
            player.position = target
            player.targetPosition = nil
            return
        }

        // Calculate rotation angle towards target
        let direction = target.v - current.v
        let angleRad = direction.toAngle()
        player.rotation = Angle(radians: angleRad)

        // Move towards target using Position2.moveTowards
        // This method already handles: returning target if distance <= maxDistance
        let newPosition = current.moveTowards(target: target, maxDistance: moveSpeed)

        // Update position
        player.position = newPosition

        // Check if reached target (moveTowards returns target when close enough)
        if newPosition == target {
            player.targetPosition = nil
        }
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
                    // Update all player systems
                    // Multiple systems can update the same player, but we only write back once
                    // to minimize @Sync setter calls and dictionary operations
                    for (playerID, var player) in state.players {
                        // Apply all system updates to the local copy
                        GameSystem.updatePlayerMovement(&player)
                        // TODO: Add other systems here, e.g.:
                        // GameSystem.updateCombat(&player)
                        // GameSystem.updateBuff(&player)
                        // GameSystem.updateHealth(&player)
                        
                        // Write back once after all systems have updated
                        // This triggers @Sync setter for dirty tracking
                        state.players[playerID] = player
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
                    // Spawn player at center of world (64.0, 36.0 in world units)
                    var player = PlayerState()
                    player.position = Position2(x: 64.0, y: 36.0)
                    player.rotation = Angle(degrees: 0.0)
                    player.targetPosition = nil as Position2?
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

                    // Update player's target position
                    if var player = state.players[playerID] {
                        player.targetPosition = event.target
                        state.players[playerID] = player
                    } else {
                        ctx.logger.warning("⚠️ MoveToEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                    }
                }
            }
        }
    }
}
