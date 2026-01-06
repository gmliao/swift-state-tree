import SwiftStateTree

// MARK: - Game State

/// Hero Defense game state definition.
/// Players can move freely, shoot monsters, and upgrade with resources.
@StateNodeBuilder
public struct HeroDefenseState: StateNodeProtocol {
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
            
            Lifetime {
                Tick(every: .milliseconds(100)) { (state: inout HeroDefenseState, ctx: LandContext) in
                    // Game logic updates (monster spawning, movement, etc.)
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
                HandleAction(PlayAction.self) { (state: inout HeroDefenseState, _: PlayAction, _: LandContext) in
                    state.score += 1
                    return PlayResponse(newScore: state.score)
                }
            }
        }
    }
}
