import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Base State

/// Base/fortress state at world center.
@StateNodeBuilder
@SnapshotConvertible
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
