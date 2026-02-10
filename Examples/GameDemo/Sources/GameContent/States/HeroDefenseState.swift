import Foundation
import SwiftStateTree

// MARK: - Game State

/// Hero Defense game state definition.
/// Players can move freely, shoot monsters, and upgrade with resources.
@StateNodeBuilder
public struct HeroDefenseState: StateNodeProtocol {
    /// Online players and their states
    @Sync(.broadcast)
    var players: ReactiveDictionary<PlayerID, PlayerState> = ReactiveDictionary<PlayerID, PlayerState>()

    /// Active monsters in the world
    @Sync(.broadcast)
    var monsters: ReactiveDictionary<Int, MonsterState> = ReactiveDictionary<Int, MonsterState>()

    /// Placed turrets
    @Sync(.broadcast)
    var turrets: ReactiveDictionary<Int, TurretState> = ReactiveDictionary<Int, TurretState>()
    
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
