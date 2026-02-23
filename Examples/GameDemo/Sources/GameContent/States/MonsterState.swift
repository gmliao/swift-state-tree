import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Monster State

/// Monster state with position, path progress, and health.
@StateNodeBuilder
@SnapshotConvertible
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
